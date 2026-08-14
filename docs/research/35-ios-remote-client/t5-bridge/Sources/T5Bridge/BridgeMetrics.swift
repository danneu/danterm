// What one bridged connection is worth reporting afterwards, and the one probe
// that measures something the bridge does not do.
//
// The counters here answer three separate questions and are kept apart on
// purpose: how much crossed the wire, how large the largest single frame was
// (the bridge's real memory bound), and how long the bridge sat blocked writing
// to the phone (its evidence that backpressure reached the app rather than a
// buffer absorbing it).
import Compression
import Foundation

/// Which way a byte is going. The two directions carry different traffic --
/// keystrokes up, a terminal's output down -- so nothing here ever pools them.
enum BridgeDirection: CustomStringConvertible {
    case uplink
    case downlink

    var description: String {
        switch self {
        case .uplink: "uplink"
        case .downlink: "downlink"
        }
    }
}

/// Counts what a stream deflater *would* have saved on the downlink, without
/// changing one byte of what is sent.
///
/// The research ledger says stream compression at the bridge is architectural
/// and safe to adopt, and that a binary tape framing is not, because deflate
/// over JSON envelopes and base64 may erase most of that tax for no protocol
/// change. That is a claim with no number behind it. This measures the number
/// and adopts nothing: T19 owns the wire format, and a prototype that quietly
/// compressed its stream would have pre-empted it.
///
/// It is a *stream* deflater rather than a per-frame one because the two differ
/// by a lot on this traffic -- every envelope repeats the same JSON keys, and
/// only a shared window across frames can pay for that.
final class DownlinkDeflateProbe {
    private let stream: UnsafeMutablePointer<compression_stream>
    private let scratch: UnsafeMutablePointer<UInt8>
    private let scratchSize = 64 * 1024
    private var initialized = false
    private(set) var deflatedBytes = 0

    init?() {
        stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: scratchSize)
        guard compression_stream_init(
            stream,
            COMPRESSION_STREAM_ENCODE,
            COMPRESSION_ZLIB
        ) == COMPRESSION_STATUS_OK else {
            stream.deallocate()
            scratch.deallocate()
            return nil
        }
        initialized = true
    }

    deinit {
        if initialized { compression_stream_destroy(stream) }
        stream.deallocate()
        scratch.deallocate()
    }

    func consume(_ bytes: UnsafeRawBufferPointer) {
        guard initialized, let base = bytes.baseAddress, bytes.count > 0 else { return }
        stream.pointee.src_ptr = base.assumingMemoryBound(to: UInt8.self)
        stream.pointee.src_size = bytes.count
        repeat {
            stream.pointee.dst_ptr = scratch
            stream.pointee.dst_size = scratchSize
            let status = compression_stream_process(stream, 0)
            deflatedBytes += scratchSize - stream.pointee.dst_size
            guard status == COMPRESSION_STATUS_OK else { return }
        } while stream.pointee.src_size > 0
    }

    /// Flushes the deflater's own buffered state, so the total is not short by
    /// whatever the window was still holding.
    func finish() {
        guard initialized else { return }
        stream.pointee.src_size = 0
        while true {
            stream.pointee.dst_ptr = scratch
            stream.pointee.dst_size = scratchSize
            let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
            deflatedBytes += scratchSize - stream.pointee.dst_size
            if status != COMPRESSION_STATUS_OK { break }
        }
    }
}

/// One direction's tally. Both directions are counted, because an asymmetry
/// between them is the whole point of the architecture -- the uplink is
/// keystrokes and the downlink is a terminal's output.
struct DirectionCounters {
    var frames = 0
    var bytes = 0
    var largestFrameBytes = 0

    mutating func record(frameBytes: Int) {
        frames += 1
        // +1 for the newline the framer consumed: what crossed the wire is the
        // line plus its delimiter, and undercounting the wire by one byte per
        // frame would flatter exactly the interactive traffic T19 cares about.
        bytes += frameBytes + 1
        largestFrameBytes = max(largestFrameBytes, frameBytes)
    }
}

/// Everything one connection reports when it ends.
///
/// `blockedWritingNanoseconds` is the load-bearing one. The bridge holds no
/// queue, so when the phone cannot keep up the bridge stalls inside a write and
/// stops reading the control socket -- which is what pushes the backpressure
/// onto the app, where the existing one-batch-in-flight coalescing lives. Time
/// spent here is therefore not a cost to fix; it is the evidence that the bound
/// is being enforced by the structure rather than asserted in a comment.
final class ConnectionMetrics: @unchecked Sendable {
    private let lock = NSLock()
    private var uplink = DirectionCounters()
    private var downlink = DirectionCounters()
    private var blockedWritingNanoseconds: UInt64 = 0
    private var deflate = DownlinkDeflateProbe()

    func recordFrame(bytes: Int, direction: BridgeDirection) {
        lock.lock()
        switch direction {
        case .uplink: uplink.record(frameBytes: bytes)
        case .downlink: downlink.record(frameBytes: bytes)
        }
        lock.unlock()
    }

    /// One forwarded downlink read: what it cost to hand to the phone, and what
    /// a deflater would have made of it. Frames are counted separately because a
    /// read and a frame are not the same unit -- one read can carry several
    /// records, or half of one.
    func recordDownlinkChunk(blockedNanoseconds: UInt64, raw: UnsafeRawBufferPointer) {
        lock.lock()
        blockedWritingNanoseconds += blockedNanoseconds
        deflate?.consume(raw)
        lock.unlock()
    }

    /// One line of counters, with every one printed even when zero: a zero here
    /// is a result, not an absence.
    ///
    /// `final` flushes the deflater, so it may be passed exactly once and only
    /// when the connection is over -- a live summary that finalized the stream
    /// would corrupt every count after it. Live summaries exist because the
    /// bridge is the only instrument that survives the phone changing networks:
    /// the console channel this spike is watched through runs over the same
    /// wifi the experiment turns off.
    func summary(final: Bool) -> String {
        lock.lock()
        defer { lock.unlock() }
        // A deflater holds its window until it is flushed, so an unfinished
        // count is not a small number -- it is not a number at all, and printing
        // it as one would read as "compression saved everything".
        let compression: String
        if final, let probe = deflate, downlink.bytes > 0 {
            // Flush first: the count is only complete once the window is out.
            probe.finish()
            let deflated = probe.deflatedBytes
            compression = "deflated=\(deflated) ratio="
                + String(format: "%.3f", Double(deflated) / Double(downlink.bytes))
                + " (measured, not applied)"
        } else if final {
            compression = "deflated=NOT-MEASURED"
        } else {
            compression = "deflated=PENDING (a stream deflater reports only when flushed)"
        }
        return "uplink frames=\(uplink.frames) bytes=\(uplink.bytes)"
            + " largestFrame=\(uplink.largestFrameBytes)"
            + " | downlink frames=\(downlink.frames) bytes=\(downlink.bytes)"
            + " largestFrame=\(downlink.largestFrameBytes)"
            + " | downlink \(compression)"
            + " | blockedWriting="
            + String(format: "%.1f", Double(blockedWritingNanoseconds) / 1e6) + "ms"
    }
}
