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

final class SpikeAppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = SpikeViewController()
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
