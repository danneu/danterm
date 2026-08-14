// The T2 spike: render one static RenderFramePlan on iOS and report, from a
// running process, which presentation paths actually put those pixels on
// screen. Three probes share one plan and one TerminalFrameBackingStore, so a
// difference between them is the presentation path and nothing else:
//
//   A -- CALayer.contents = CGImage, the H2 candidate.
//   B -- CALayer.contents = IOSurface, the direct analogue of the macOS
//        swapchain; undocumented on iOS, so this probe exists to find out.
//   C -- UIGraphicsImageRenderer + TerminalFrameBackingStore.blit, which
//        exercises the store's own blit seam against a UIKit context.
//
// Every probe logs one SPIKE line so `simctl launch --console` is a transcript,
// and the three results are stacked on screen so one screenshot settles which
// of them produced pixels.
import CoreGraphics
import TerminalCore
import TerminalRenderExecution
import TerminalRenderPlanning
import UIKit

private func log(_ message: String) {
    // print, not NSLog: simctl launch --console-pipe forwards stdout, and the
    // unified log adds a subsystem filter this spike does not need.
    print("SPIKE \(message)")
    fflush(stdout)
}

/// The fixed sample frame every probe presents: enough styling that a blank
/// result cannot be mistaken for a correctly rendered empty grid.
private func makeSamplePlan(columns: Int, rows: Int) -> RenderFramePlan? {
    guard var terminal = Terminal(columns: columns, rows: rows) else { return nil }
    var input = "\u{1B}[2J\u{1B}[H"
    input += "DanTerm on iOS -- T2 spike\r\n"
    input += "\u{1B}[31mred\u{1B}[0m \u{1B}[32mgreen\u{1B}[0m \u{1B}[34mblue\u{1B}[0m\r\n"
    input += "\u{1B}[1mbold\u{1B}[0m \u{1B}[3mitalic\u{1B}[0m \u{1B}[4munderline\u{1B}[0m\r\n"
    input += "\u{1B}[7mreverse\u{1B}[0m box: \u{2502}\u{250C}\u{2500}\u{2510} blocks: \u{2588}\u{2592}\u{2591}\r\n"
    input += "powerline: \u{E0B0}\u{E0B2}  braille: \u{2833}\u{28FF}\r\n"
    // Private-use scalars no sprite family draws, so these render only if the
    // packaged Nerd Font symbols resource loaded from the bundle. The spike
    // cannot ask NerdFontSymbolsResource.packaged directly -- it is `package`
    // access -- so the glyphs themselves are the probe.
    input += "nerd font: \u{F09B} \u{E795} \u{F121}\r\n"
    input += "$ echo hello && ls -la /tmp\r\n"
    for row in 8...rows {
        input += "line \(row): the quick brown fox jumps\r\n"
    }
    terminal.feed(Array(input.utf8))
    return planFrame(
        for: terminal,
        presentation: RenderPresentation(
            theme: .dark,
            isCursorVisible: true,
            cursorShape: .block
        )
    )
}

/// A visibly different frame at the same geometry, for probe D.
private func makeSecondPlan(columns: Int, rows: Int) -> RenderFramePlan? {
    guard var terminal = Terminal(columns: columns, rows: rows) else { return nil }
    var input = "\u{1B}[2J\u{1B}[H"
    for row in 1...rows {
        input += "\u{1B}[43;30mSECOND FRAME row \(row)\u{1B}[0m\r\n"
    }
    terminal.feed(Array(input.utf8))
    return planFrame(
        for: terminal,
        presentation: RenderPresentation(
            theme: .dark,
            isCursorVisible: false,
            cursorShape: .block
        )
    )
}

/// One frame of probe F's animation: a whole-screen repaint whose background
/// color and counter both change every frame, so a stale presentation is
/// unmistakable rather than a subtle difference.
private func makeCounterPlan(columns: Int, rows: Int, index: Int) -> RenderFramePlan? {
    guard var terminal = Terminal(columns: columns, rows: rows) else { return nil }
    let background = 41 + (index % 6)
    var input = "\u{1B}[2J\u{1B}[H"
    for row in 1...rows {
        // No trailing newline on the last row: one would scroll the frame and
        // put a blank line where the counter should be.
        input += "\u{1B}[\(background);30m FRAME \(index) row \(row) \u{1B}[0m"
        if row < rows { input += "\r\n" }
    }
    terminal.feed(Array(input.utf8))
    return planFrame(
        for: terminal,
        presentation: RenderPresentation(
            theme: .dark,
            isCursorVisible: false,
            cursorShape: .block
        )
    )
}

/// Wraps the store's pixels as a CGImage the same way `blit` does, so probe A
/// and probe C differ only in who rasterizes.
private func makeImage(from store: TerminalFrameBackingStore) -> CGImage? {
    let surface = store.ioSurface
    surface.lock(options: [.readOnly], seed: nil)
    defer { surface.unlock(options: [.readOnly], seed: nil) }
    let byteCount = surface.bytesPerRow * surface.height
    // Copy: the CGImage outlives this call as layer contents, and the store
    // keeps mutating its surface. A no-copy provider would be a dangling
    // borrow the moment a second frame renders.
    guard let data = CFDataCreate(
        nil,
        surface.baseAddress.assumingMemoryBound(to: UInt8.self),
        byteCount
    ), let provider = CGDataProvider(data: data) else { return nil }
    return CGImage(
        width: surface.width,
        height: surface.height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: surface.bytesPerRow,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )
}

/// Counts non-background pixels in a rendered CGImage, so "the plan reached the
/// pixels" is a number rather than a look at a screenshot.
private func inkPixelCount(of image: CGImage) -> Int {
    guard let data = image.dataProvider?.data,
          let bytes = CFDataGetBytePtr(data)
    else { return -1 }
    let stride = image.bytesPerRow
    var count = 0
    // The plan's default background is the dark theme's; any pixel differing
    // from the top-left corner pixel is ink of some kind.
    let base = (bytes[0], bytes[1], bytes[2])
    for y in 0..<image.height {
        for x in 0..<image.width {
            let offset = y * stride + x * 4
            if (bytes[offset], bytes[offset + 1], bytes[offset + 2]) != base {
                count += 1
            }
        }
    }
    return count
}

final class SpikeViewController: UIViewController {
    // Probes D and E in order, each returning the banner text for the stage it
    // just produced. On a device the user drives them by tapping, so a
    // screenshot can be taken with the stage named on screen; the simulator
    // keeps the timers the scripted run screenshots against.
    private var pendingStages: [() -> String] = []
    private var stageBanner: UILabel?

    // Recolored by a tap in ablation mode purely to force a compositing pass.
    private var compositeTriggerMarker: UIView?

    // Probe F's state. The run loop owns the timer, so it outlives this
    // controller; its block holds `self` weakly and invalidates the timer the
    // first time it fires with `self` gone, which is the whole teardown path.
    private var swapchain: TerminalFrameSwapchain?
    private var swapchainView: UIView?
    private var swapchainTimer: Timer?
    private var swapchainFrameIndex = 0

    /// Probe F -- the positive control for the ablation. Drives a layer from
    /// the real `TerminalFrameSwapchain`, which never mutates an attached
    /// buffer: it renders into a detached one and then attaches it. If the
    /// indeterminate presentation the ablation produced is caused by mutating
    /// an attached surface, this path must be stable instead.
    ///
    /// Runs alone on screen, without probes A through E, so nothing else can be
    /// mistaken for its output.
    private func runSwapchainProbe(
        metrics: TerminalRenderMetrics,
        columns: Int,
        rows: Int,
        scale: CGFloat,
        banner: UILabel
    ) {
        guard let swapchain = TerminalFrameSwapchain(
            columns: columns,
            rows: rows,
            metrics: metrics
        ) else {
            log("PROBE-F FAIL TerminalFrameSwapchain returned nil")
            banner.text = "F: swapchain allocation FAILED"
            return
        }
        self.swapchain = swapchain
        log("PROBE-F swapchain allocated depth=\(TerminalFrameSwapchain.defaultDepth)")

        let panel = UIView(frame: CGRect(
            x: 8,
            y: banner.frame.maxY + 12,
            width: CGFloat(metrics.cellWidthPixels * columns) / scale,
            height: CGFloat(metrics.cellHeightPixels * rows) / scale
        ))
        panel.layer.contentsScale = scale
        panel.layer.magnificationFilter = .nearest
        view.addSubview(panel)
        swapchainView = panel

        banner.text = "F: swapchain driving the layer"
        // 100 frames at 10Hz, then a deliberate stop. The animation shows
        // whether every published frame reaches the screen; the stop shows
        // whether the last one stays there, which is where the ablation's
        // stale frame reappeared.
        swapchainTimer = Timer.scheduledTimer(
            withTimeInterval: 0.1,
            repeats: true
        ) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            guard self.swapchainFrameIndex < 100 else {
                timer.invalidate()
                self.swapchainTimer = nil
                let last = self.swapchainFrameIndex - 1
                log("PROBE-F stopped after frame \(last); nothing further is published")
                banner.text = "F: STOPPED at frame \(last) -- watch for reversion"
                return
            }
            guard let plan = makeCounterPlan(
                columns: columns,
                rows: rows,
                index: self.swapchainFrameIndex
            ) else { return }
            if let store = swapchain.publish(plan: plan, damage: .full) {
                self.swapchainView?.layer.contents = store.ioSurface
            } else {
                log("PROBE-F frame \(self.swapchainFrameIndex) coalesced; no buffer acquirable")
            }
            self.swapchainFrameIndex += 1
        }
    }

    @objc private func handleTap() {
        advanceStage()
    }

    @objc private func handleAblationTap() {
        guard let marker = compositeTriggerMarker else { return }
        marker.backgroundColor = marker.backgroundColor == .cyan ? .magenta : .cyan
        log("TAP composite trigger: recolored the marker, touched nothing else")
    }

    private func advanceStage() {
        guard !pendingStages.isEmpty else { return }
        stageBanner?.text = pendingStages.removeFirst()()
        if pendingStages.isEmpty {
            stageBanner?.text = (stageBanner?.text ?? "") + " -- last stage"
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemPink

        let scale = view.window?.screen.scale ?? UIScreen.main.scale
        log("displayScale=\(scale)")

        guard let metrics = TerminalRenderMetrics(displayScale: scale, fontSize: 11) else {
            log("FAIL TerminalRenderMetrics returned nil")
            return
        }
        log("metrics cell=\(metrics.cellSize) pixels=\(metrics.cellWidthPixels)x\(metrics.cellHeightPixels)")

        let columns = max(20, Int(view.bounds.width / metrics.cellSize.width))
        let rows = 12

        #if !targetEnvironment(simulator)
        if ProcessInfo.processInfo.environment["SPIKE_MODE"] == "swapchain" {
            let banner = UILabel(frame: CGRect(x: 8, y: 64, width: 400, height: 16))
            banner.font = .systemFont(ofSize: 12, weight: .bold)
            banner.textColor = .yellow
            view.addSubview(banner)
            runSwapchainProbe(
                metrics: metrics,
                columns: columns,
                rows: rows,
                scale: scale,
                banner: banner
            )
            return
        }
        #endif

        guard let plan = makeSamplePlan(columns: columns, rows: rows) else {
            log("FAIL Terminal(columns:rows:) returned nil")
            return
        }
        log("plan \(plan.columns)x\(plan.rows) textRuns=\(plan.textRuns.count) bgRuns=\(plan.backgroundRuns.count) cursor=\(plan.cursor != nil)")

        guard let store = TerminalFrameBackingStore(
            columns: columns,
            rows: rows,
            metrics: metrics
        ) else {
            log("FAIL TerminalFrameBackingStore returned nil (IOSurface or CGContext refused)")
            return
        }
        log("store ok ioSurface=\(store.ioSurface.width)x\(store.ioSurface.height) bytesPerRow=\(store.ioSurface.bytesPerRow)")

        store.renderFull(plan)
        log("renderFull returned")

        guard let image = makeImage(from: store) else {
            log("FAIL could not wrap store pixels as CGImage")
            return
        }
        let ink = inkPixelCount(of: image)
        log("PROBE-INK non-background pixels in the rendered store: \(ink)")

        let swapchain = TerminalFrameSwapchain(columns: columns, rows: rows, metrics: metrics)
        log("PROBE-SWAPCHAIN allocated=\(swapchain != nil) published=\(swapchain?.publish(plan: plan, damage: .full) != nil)")

        let pointSize = store.pointSize
        // Below the status bar, which would otherwise composite over the first
        // probe and make one panel look like it rendered differently.
        var y: CGFloat = 64

        func label(_ text: String) {
            let label = UILabel(frame: CGRect(x: 8, y: y, width: 400, height: 16))
            label.text = text
            label.font = .systemFont(ofSize: 12, weight: .semibold)
            label.textColor = .white
            view.addSubview(label)
            y += 18
        }

        // Names the stage on screen, so a screenshot carries which probe
        // produced it instead of relying on when it was taken.
        let banner = UILabel(frame: CGRect(x: 8, y: y, width: 400, height: 16))
        banner.font = .systemFont(ofSize: 12, weight: .bold)
        banner.textColor = .yellow
        view.addSubview(banner)
        stageBanner = banner
        y += 22

        // Probe A -- CGImage as layer contents.
        label("A: CALayer.contents = CGImage")
        let a = UIView(frame: CGRect(origin: CGPoint(x: 8, y: y), size: pointSize))
        a.layer.contentsScale = scale
        a.layer.magnificationFilter = .nearest
        a.layer.contents = image
        view.addSubview(a)
        log("PROBE-A CGImage assigned to layer.contents; contents is nil: \(a.layer.contents == nil)")
        y += pointSize.height + 12

        // Probe B -- IOSurface as layer contents. Undocumented on iOS; the
        // point of the probe is whether CoreAnimation keeps or drops it.
        label("B: CALayer.contents = IOSurface")
        let b = UIView(frame: CGRect(origin: CGPoint(x: 8, y: y), size: pointSize))
        b.layer.contentsScale = scale
        b.layer.magnificationFilter = .nearest
        b.layer.contents = store.ioSurface
        let bKept = b.layer.contents != nil
        view.addSubview(b)
        log("PROBE-B IOSurface assigned to layer.contents; retained by CoreAnimation: \(bKept)")
        y += pointSize.height + 12

        // Probe C -- the store's own blit seam against a UIKit context.
        label("C: TerminalFrameBackingStore.blit into a UIKit context")
        let renderer = UIGraphicsImageRenderer(size: pointSize)
        let blitted = renderer.image { context in
            store.blit(into: context.cgContext, rect: CGRect(origin: .zero, size: pointSize))
        }
        let blitInk = blitted.cgImage.map(inkPixelCount(of:)) ?? -1
        log("PROBE-C blit into a UIKit context produced non-background pixels: \(blitInk)")
        let c = UIImageView(image: blitted)
        c.frame = CGRect(origin: CGPoint(x: 8, y: y), size: pointSize)
        view.addSubview(c)

        log("PROBE-INUSE right after attach, ioSurface.isInUse=\(store.ioSurface.isInUse)")

        // Probe D -- mutate the store's pixels in place and touch nothing else.
        // Probes A and C hold copies, so only B can change; if it does,
        // CoreAnimation is sampling the surface live rather than at assignment.
        let probeD: () -> String = {
            guard let second = makeSecondPlan(columns: columns, rows: rows) else {
                log("PROBE-D FAIL could not build the second plan")
                return "D FAILED"
            }
            store.renderFull(second)
            log("PROBE-D rendered a second plan into the same store; nothing reattached")
            log("PROBE-INUSE while attached, ioSurface.isInUse=\(store.ioSurface.isInUse)")
            return "D: mutated in place, NOTHING reattached"
        }

        // Probe E -- reassign the same surface as contents. This is what the
        // macOS swapchain's publish actually does (render into a detached
        // buffer, then attach it), so this, not probe D, is the test of whether
        // the swapchain protocol carries to iOS at all.
        let probeE: () -> String = { [weak b] in
            guard let b else { return "E: view gone" }
            b.layer.contents = nil
            b.layer.contents = store.ioSurface
            log("PROBE-E reattached the same IOSurface as layer.contents")
            return "E: same surface REATTACHED"
        }

        #if targetEnvironment(simulator)
        // The scripted simulator run screenshots on a clock, so keep the clock.
        banner.text = "C: first frame (timed run)"
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { _ = probeD() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { _ = probeE() }
        #else
        // On a device there is no scripted screenshot, so the run is driven by
        // hand. Two modes, because the tap that advances a stage is itself a
        // composite trigger and would otherwise be confounded with the mutation
        // it is supposed to reveal.
        if ProcessInfo.processInfo.environment["SPIKE_MODE"] == "ablate" {
            // Probe D fires on a clock, and nothing else on screen changes with
            // it: no banner update, no touch. So if panel B changes on its own,
            // an in-place mutation reaches the display with no compositing pass
            // that this app asked for. The tap here deliberately does NOT run a
            // stage -- it recolors one unrelated square, which dirties the
            // window and forces a composite while leaving the store and panel
            // B's contents alone.
            banner.text = "ABLATION: do not touch. D fires at 8s."
            let marker = UIView(frame: CGRect(x: 320, y: 64, width: 24, height: 24))
            marker.backgroundColor = .cyan
            view.addSubview(marker)
            compositeTriggerMarker = marker
            view.addGestureRecognizer(
                UITapGestureRecognizer(target: self, action: #selector(handleAblationTap))
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                _ = probeD()
                log("PROBE-D-ABLATION fired on a timer; no banner update, no touch")
            }
        } else {
            banner.text = "C: first frame -- TAP to advance"
            pendingStages = [probeD, probeE]
            view.addGestureRecognizer(
                UITapGestureRecognizer(target: self, action: #selector(handleTap))
            )
        }
        #endif

        log("DONE")
    }
}

/// One arm's samples. Every aggregate this reports is printed beside its own
/// sample count, so "not measured" cannot render as a reassuring zero.
private struct ArmSamples {
    let name: String
    /// Building the frame plan: identical work in both arms, and nothing the
    /// presentation path can reach. It is the control -- if it moves between
    /// arms, the run measured the machine's state, not the presentation path.
    var planNanoseconds: [UInt64] = []
    /// Producing the presented layer contents from that plan, which is the
    /// whole difference between the arms.
    var presentNanoseconds: [UInt64] = []
    /// Gap between consecutive display-link ticks. The continuous form of
    /// "did it hold the frame rate", kept instead of a dropped-frame verdict.
    var tickNanoseconds: [UInt64] = []
    /// Publishes that acquired no buffer (swapchain) or images that failed to
    /// build (copy). Either one means a frame did not reach the layer.
    var missedPresentations = 0
}

private func percentile(_ samples: [UInt64], _ fraction: Double) -> UInt64 {
    guard !samples.isEmpty else { return 0 }
    let sorted = samples.sorted()
    let rank = Int((Double(sorted.count - 1) * fraction).rounded())
    return sorted[rank]
}

private func report(_ label: String, _ samples: [UInt64]) {
    // n first, and unconditionally: an aggregate without its sample count
    // cannot distinguish "no cost" from "no samples".
    guard !samples.isEmpty else {
        log("BENCH \(label) n=0 NOT-MEASURED")
        return
    }
    let micros = { (value: UInt64) in String(format: "%.1f", Double(value) / 1000) }
    log("BENCH \(label) n=\(samples.count)"
        + " p50=\(micros(percentile(samples, 0.5)))us"
        + " p95=\(micros(percentile(samples, 0.95)))us"
        + " p99=\(micros(percentile(samples, 0.99)))us"
        + " max=\(micros(samples.max() ?? 0))us")
}

/// T3's measurement half: the real `TerminalFrameSwapchain` against
/// CGImage-copy-per-frame, under a full-repaint scroll workload at a
/// phone-typical grid.
///
/// The arms alternate in blocks inside one run rather than running as two
/// sessions, because a comparison across sessions measures the machine as much
/// as the code. Both arms render the same plan sequence into the same grid, and
/// both are driven by the display link at the display's own cadence.
final class BenchViewController: UIViewController {
    private static let framesPerBlock = 120

    /// Which arm runs each block, and whether the block is recorded.
    ///
    /// Three properties this schedule must have, each learned from a run that
    /// lacked it:
    ///
    /// - The first blocks are discarded. Launch warmup is worth hundreds of
    ///   milliseconds and lands entirely in whichever arm goes first.
    /// - The recorded blocks are balanced against drift, not alternating. Plain
    ///   alternation puts one arm in every even block, so any warming or
    ///   thermal trend across the run is charged to one arm.
    /// - A third arm presents nothing. The plan build was meant to be a control
    ///   the presentation path could not reach, and it turned out to differ by
    ///   arm at a steady 35%, so it is not one. `plan-only` is the arm that
    ///   says what the plan build costs when no presentation runs beside it,
    ///   which is what separates "this arm slows its neighbour" from "this arm
    ///   was measured while the machine was busy".
    private static let schedule: [(arm: Int, record: Bool)] = [
        (0, false), (1, false), (2, false),
        (0, true), (1, true), (2, true), (2, true), (1, true), (0, true),
        (0, true), (1, true), (2, true), (2, true), (1, true), (0, true),
    ]

    private var panel: UIView?
    private var banner: UILabel?
    private var terminal: Terminal?
    private var swapchain: TerminalFrameSwapchain?
    /// The copy arm's scratch store. It is never attached, so rewriting it in
    /// place is safe -- what reaches the layer is an immutable CGImage copy.
    private var copyStore: TerminalFrameBackingStore?
    private var displayLink: CADisplayLink?
    private var arms: [ArmSamples] = []
    private var frameInBlock = 0
    private var blockIndex = 0
    private var lastTickNanoseconds: UInt64 = 0
    private var columns = 0
    private var rows = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let scale = view.window?.screen.scale ?? UIScreen.main.scale
        guard let metrics = TerminalRenderMetrics(displayScale: scale, fontSize: 11) else {
            log("BENCH FAIL TerminalRenderMetrics returned nil")
            return
        }
        columns = max(20, Int(view.bounds.width / metrics.cellSize.width))
        rows = max(10, Int((view.bounds.height - 80) / metrics.cellSize.height))
        log("BENCH grid=\(columns)x\(rows) displayScale=\(scale) fontSize=11")

        guard var terminal = Terminal(columns: columns, rows: rows),
              let swapchain = TerminalFrameSwapchain(
                  columns: columns, rows: rows, metrics: metrics
              ),
              let copyStore = TerminalFrameBackingStore(
                  columns: columns, rows: rows, metrics: metrics
              )
        else {
            log("BENCH FAIL could not build the engine, swapchain, or store")
            return
        }
        terminal.feed(Array("\u{1B}[2J\u{1B}[H".utf8))
        self.terminal = terminal
        self.swapchain = swapchain
        self.copyStore = copyStore

        let banner = UILabel(frame: CGRect(x: 8, y: 44, width: 400, height: 16))
        banner.font = .systemFont(ofSize: 12, weight: .bold)
        banner.textColor = .yellow
        banner.text = "BENCH running"
        view.addSubview(banner)
        self.banner = banner

        let panel = UIView(frame: CGRect(
            x: 0,
            y: 68,
            width: CGFloat(metrics.cellWidthPixels * columns) / scale,
            height: CGFloat(metrics.cellHeightPixels * rows) / scale
        ))
        panel.layer.contentsScale = scale
        panel.layer.magnificationFilter = .nearest
        view.addSubview(panel)
        self.panel = panel

        arms = [
            ArmSamples(name: "swapchain"),
            ArmSamples(name: "cgimage-copy"),
            ArmSamples(name: "plan-only"),
        ]
        log("BENCH thermalState at start: \(ProcessInfo.processInfo.thermalState.rawValue)")

        if ProcessInfo.processInfo.environment["SPIKE_MODE"] == "bench-sat" {
            // Saturated: answers what a frame costs. Per-frame microseconds are
            // comparable across arms only here, because the thread never idles
            // into a lower CPU power state between frames.
            log("BENCH pacing=saturated (per-frame cost; tick-gap is meaningless)")
            banner.text = "BENCH saturated"
            DispatchQueue.main.async { [weak self] in
                self?.runSaturatedBlock()
            }
            return
        }
        // Paced: answers whether the cadence holds. The display link drives
        // every arm, so none is measured at a cadence the others did not face.
        // Per-frame costs from this pacing are NOT comparable across arms --
        // the arms idle differently between vsyncs and so run at different CPU
        // clocks.
        log("BENCH pacing=display-link (cadence; per-frame costs not comparable)")
        let link = CADisplayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func step(_ link: CADisplayLink) {
        let block = Self.schedule[blockIndex]
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        if lastTickNanoseconds != 0, block.record {
            arms[block.arm].tickNanoseconds.append(now - lastTickNanoseconds)
        }
        lastTickNanoseconds = now
        runFrame(armIndex: block.arm, recording: block.record)
        frameInBlock += 1
        guard frameInBlock >= Self.framesPerBlock else { return }
        endOfBlock {
            link.invalidate()
            self.displayLink = nil
        }
    }

    /// Saturated pacing: every arm's frames run back to back, one block per
    /// main-queue hop.
    ///
    /// The display-link pacing this replaces leaves the main thread idle
    /// between vsyncs, and how idle depends on how much the arm does -- so the
    /// arms sat in different CPU power states and their per-frame microseconds
    /// were not comparable. Saturating the thread keeps the clock up for every
    /// arm. The hop between blocks is what keeps the watchdog happy; a block is
    /// well under a second.
    private func runSaturatedBlock() {
        let block = Self.schedule[blockIndex]
        for _ in 0..<Self.framesPerBlock {
            runFrame(armIndex: block.arm, recording: block.record)
        }
        endOfBlock { }
        guard displayLink == nil, blockIndex < Self.schedule.count else { return }
        DispatchQueue.main.async { [weak self] in
            self?.runSaturatedBlock()
        }
    }

    private func runFrame(armIndex: Int, recording: Bool) {

        // The control: same work, same inputs, in both arms.
        let planStart = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        guard var terminal else { return }
        let line = "\u{1B}[3\(frameInBlock % 7)m"
            + "block \(blockIndex) frame \(frameInBlock): "
            + "the quick brown fox jumps over the lazy dog\u{1B}[0m\r\n"
        terminal.feed(Array(line.utf8))
        self.terminal = terminal
        guard let plan = planFrame(
            for: terminal,
            presentation: RenderPresentation(
                theme: .dark,
                isCursorVisible: true,
                cursorShape: .block
            )
        ) as RenderFramePlan? else {
            if recording { arms[armIndex].missedPresentations += 1 }
            return
        }
        if recording {
            arms[armIndex].planNanoseconds.append(
                clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - planStart
            )
        }

        // The arms diverge only here.
        let presentStart = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        if armIndex == 0 {
            if let store = swapchain?.publish(plan: plan, damage: .full) {
                panel?.layer.contents = store.ioSurface
            } else if recording {
                arms[armIndex].missedPresentations += 1
            }
        } else if armIndex == 1, let copyStore {
            copyStore.renderFull(plan)
            if let image = makeImage(from: copyStore) {
                panel?.layer.contents = image
            } else if recording {
                arms[armIndex].missedPresentations += 1
            }
        }
        // armIndex 2 is plan-only: it deliberately presents nothing, so its
        // `present` samples are the cost of the measurement itself.
        if recording {
            arms[armIndex].presentNanoseconds.append(
                clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - presentStart
            )
        }
    }

    private func endOfBlock(_ stopPacing: () -> Void) {
        // The pooled control can hide a trend that ran through the whole
        // session, so each block reports its own before the arms are pooled.
        let block = Self.schedule[blockIndex]
        let control = arms[block.arm].planNanoseconds.suffix(Self.framesPerBlock)
        log("BENCH block \(blockIndex) arm=\(arms[block.arm].name)"
            + " recorded=\(block.record)"
            + " plan-control-p50="
            + String(format: "%.1f", Double(percentile(Array(control), 0.5)) / 1000)
            + "us thermal=\(ProcessInfo.processInfo.thermalState.rawValue)")
        frameInBlock = 0
        blockIndex += 1
        // A block boundary changes which arm runs, so the tick gap across it
        // would be charged to the wrong arm.
        lastTickNanoseconds = 0
        guard blockIndex >= Self.schedule.count else { return }
        stopPacing()
        finish()
    }

    private func finish() {
        log("BENCH thermalState at end: \(ProcessInfo.processInfo.thermalState.rawValue)")
        let recorded = Self.schedule.filter(\.record).count
        log("BENCH blocks=\(Self.schedule.count) recorded=\(recorded)"
            + " framesPerBlock=\(Self.framesPerBlock)"
            + " ABBA-balanced, warmup discarded, one run, one session")
        for arm in arms {
            report("\(arm.name) plan-control", arm.planNanoseconds)
            report("\(arm.name) present", arm.presentNanoseconds)
            report("\(arm.name) tick-gap", arm.tickNanoseconds)
            log("BENCH \(arm.name) missedPresentations=\(arm.missedPresentations)")
        }
        log("BENCH energy: NOT-MEASURED (no Instruments attach in this recipe)")
        banner?.text = "BENCH done -- see the console"
        log("BENCH DONE")
    }
}

/// Process CPU seconds, user plus system. Negative means the call failed, so a
/// failure cannot be read as "used no CPU".
private func processCPUSeconds() -> Double {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return -1 }
    let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
    let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
    return user + system
}

/// What a terminal actually does to a screen, as opposed to a full repaint
/// every frame. One cycle is a burst of command output, then some typing, then
/// a long idle -- and the idle is the point, not a gap between the parts that
/// matter.
private enum WorkloadPhase {
    case output   // lines arriving: scroll damage
    case typing   // one echoed cell
    case idle     // nothing; the phone should be free to ramp down

    static func at(nanosecondsIntoCycle elapsed: UInt64) -> WorkloadPhase {
        switch elapsed {
        case ..<250_000_000: .output
        case ..<600_000_000: .typing
        default: .idle
        }
    }
}

/// T3's energy arm: the same two presentation paths under a bursty,
/// incrementally damaged workload, measured by how much CPU time the process
/// spends over a fixed wall clock.
///
/// This exists because the frame-cost benchmark answers a question a terminal
/// never asks. It runs continuous full-repaint animation, which is both the
/// copy path's best case -- the swapchain exists to repaint only damaged rows
/// -- and a workload that denies the phone the idle it would really have. Here
/// the damage comes from the engine via `drainDamage()`, a frame is presented
/// only when something changed, and most of the wall clock is idle.
///
/// The metric is a proxy, not joules: over the same wall clock and the same
/// delivered frames, the arm that uses less CPU time leaves the phone idle
/// longer.
final class EnergyViewController: UIViewController {
    private static let cycleNanoseconds: UInt64 = 2_000_000_000
    private static let warmupNanoseconds: UInt64 = 3_000_000_000
    private static let recordedNanoseconds: UInt64 = 6_000_000_000
    private static let schedule: [(arm: Int, record: Bool)] = [
        (0, false), (1, false), (2, false),
        (0, true), (1, true), (2, true), (2, true), (1, true), (0, true),
    ]

    private struct EnergyArm {
        let name: String
        var cpuSeconds = 0.0
        var wallSeconds = 0.0
        var framesPresented = 0
        var damagedRows: [UInt64] = []
        var cpuUnavailable = false
    }

    private var panel: UIView?
    private var banner: UILabel?
    private var terminal: Terminal?
    private var swapchain: TerminalFrameSwapchain?
    private var copyStore: TerminalFrameBackingStore?
    private var displayLink: CADisplayLink?
    private var arms: [EnergyArm] = []
    private var blockIndex = 0
    private var blockStartNanoseconds: UInt64 = 0
    private var blockStartCPU = 0.0
    private var cycleStartNanoseconds: UInt64 = 0
    private var typedColumn = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let scale = view.window?.screen.scale ?? UIScreen.main.scale
        guard let metrics = TerminalRenderMetrics(displayScale: scale, fontSize: 11) else {
            log("ENERGY FAIL TerminalRenderMetrics returned nil")
            return
        }
        let columns = max(20, Int(view.bounds.width / metrics.cellSize.width))
        let rows = max(10, Int((view.bounds.height - 80) / metrics.cellSize.height))
        log("ENERGY grid=\(columns)x\(rows) displayScale=\(scale)")

        guard var terminal = Terminal(columns: columns, rows: rows),
              let swapchain = TerminalFrameSwapchain(
                  columns: columns, rows: rows, metrics: metrics
              ),
              let copyStore = TerminalFrameBackingStore(
                  columns: columns, rows: rows, metrics: metrics
              )
        else {
            log("ENERGY FAIL could not build the engine, swapchain, or store")
            return
        }
        terminal.feed(Array("\u{1B}[2J\u{1B}[H".utf8))
        _ = terminal.drainDamage()
        self.terminal = terminal
        self.swapchain = swapchain
        self.copyStore = copyStore

        let banner = UILabel(frame: CGRect(x: 8, y: 44, width: 400, height: 16))
        banner.font = .systemFont(ofSize: 12, weight: .bold)
        banner.textColor = .yellow
        banner.text = "ENERGY running"
        view.addSubview(banner)
        self.banner = banner

        let panel = UIView(frame: CGRect(
            x: 0,
            y: 68,
            width: CGFloat(metrics.cellWidthPixels * columns) / scale,
            height: CGFloat(metrics.cellHeightPixels * rows) / scale
        ))
        panel.layer.contentsScale = scale
        panel.layer.magnificationFilter = .nearest
        view.addSubview(panel)
        self.panel = panel

        arms = [
            EnergyArm(name: "swapchain"),
            EnergyArm(name: "cgimage-copy"),
            EnergyArm(name: "plan-only"),
        ]
        log("ENERGY cycle=2s (0.25s output, 0.35s typing, 1.4s idle);"
            + " damage from drainDamage(), never .full")
        let link = CADisplayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        if blockStartNanoseconds == 0 {
            blockStartNanoseconds = now
            cycleStartNanoseconds = now
            blockStartCPU = processCPUSeconds()
        }
        let block = Self.schedule[blockIndex]

        if now - cycleStartNanoseconds >= Self.cycleNanoseconds {
            cycleStartNanoseconds = now
        }
        feed(phase: WorkloadPhase.at(nanosecondsIntoCycle: now - cycleStartNanoseconds))
        present(armIndex: block.arm, recording: block.record)

        let duration = block.record ? Self.recordedNanoseconds : Self.warmupNanoseconds
        guard now - blockStartNanoseconds >= duration else { return }
        endOfBlock(now: now, link: link)
    }

    private func feed(phase: WorkloadPhase) {
        guard var terminal else { return }
        switch phase {
        case .output:
            let line = "\u{1B}[32m$\u{1B}[0m building target \(blockIndex): "
                + "the quick brown fox jumps over the lazy dog\r\n"
            terminal.feed(Array(line.utf8))
        case .typing:
            typedColumn += 1
            terminal.feed(Array("x".utf8))
        case .idle:
            break
        }
        self.terminal = terminal
    }

    private func present(armIndex: Int, recording: Bool) {
        guard var terminal else { return }
        let damage = terminal.drainDamage()
        self.terminal = terminal
        // No damage, no frame. This is the whole reason the idle phase costs
        // anything at all to measure: a path that repaints regardless would
        // show up right here.
        guard !damage.isEmpty else { return }
        guard let plan = planFrame(
            for: terminal,
            presentation: RenderPresentation(
                theme: .dark,
                isCursorVisible: true,
                cursorShape: .block
            )
        ) as RenderFramePlan? else { return }

        if armIndex == 0 {
            if let store = swapchain?.publish(plan: plan, damage: damage) {
                panel?.layer.contents = store.ioSurface
            }
        } else if armIndex == 1, let copyStore {
            // The copy path cannot use the damage: whatever changed, the whole
            // frame is copied to build the image it presents.
            if !copyStore.apply(plan: plan, damage: damage) {
                copyStore.renderFull(plan)
            }
            if let image = makeImage(from: copyStore) {
                panel?.layer.contents = image
            }
        }
        guard recording else { return }
        arms[armIndex].framesPresented += 1
        arms[armIndex].damagedRows.append(UInt64(damage.damagedRowCount))
    }

    private func endOfBlock(now: UInt64, link: CADisplayLink) {
        let block = Self.schedule[blockIndex]
        let cpu = processCPUSeconds()
        let wall = Double(now - blockStartNanoseconds) / 1e9
        if block.record {
            if cpu < 0 || blockStartCPU < 0 {
                arms[block.arm].cpuUnavailable = true
            } else {
                arms[block.arm].cpuSeconds += cpu - blockStartCPU
            }
            arms[block.arm].wallSeconds += wall
        }
        log("ENERGY block \(blockIndex) arm=\(arms[block.arm].name)"
            + " recorded=\(block.record)"
            + String(format: " wall=%.2fs cpu=%.3fs", wall, max(0, cpu - blockStartCPU))
            + " thermal=\(ProcessInfo.processInfo.thermalState.rawValue)")

        blockIndex += 1
        blockStartNanoseconds = 0
        guard blockIndex >= Self.schedule.count else { return }
        link.invalidate()
        displayLink = nil
        finish()
    }

    private func finish() {
        for arm in arms {
            guard !arm.cpuUnavailable, arm.wallSeconds > 0 else {
                log("ENERGY \(arm.name) NOT-MEASURED"
                    + " (cpuUnavailable=\(arm.cpuUnavailable) wall=\(arm.wallSeconds))")
                continue
            }
            let duty = arm.cpuSeconds / arm.wallSeconds * 100
            log("ENERGY \(arm.name)"
                + String(format: " cpu=%.3fs wall=%.2fs duty=%.1f%%",
                         arm.cpuSeconds, arm.wallSeconds, duty)
                + " frames=\(arm.framesPresented)"
                + " damagedRows p50=\(percentile(arm.damagedRows, 0.5))"
                + " p95=\(percentile(arm.damagedRows, 0.95))"
                + " n=\(arm.damagedRows.count)")
        }
        log("ENERGY note: CPU time is a proxy for energy, not a joule count.")
        banner?.text = "ENERGY done -- see the console"
        log("ENERGY DONE")
    }
}

final class SpikeAppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        let mode = ProcessInfo.processInfo.environment["SPIKE_MODE"]
        let root: UIViewController = switch mode {
        case "bench", "bench-sat": BenchViewController()
        case "energy": EnergyViewController()
        case "client": T23ClientSmokeViewController()
        default: SpikeViewController()
        }
        window.rootViewController = root
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}

UIApplicationMain(
    CommandLine.argc,
    CommandLine.unsafeArgv,
    nil,
    NSStringFromClass(SpikeAppDelegate.self)
)
