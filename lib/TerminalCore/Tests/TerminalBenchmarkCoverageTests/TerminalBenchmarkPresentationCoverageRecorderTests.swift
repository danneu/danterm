// Behavioral proofs that continuous coverage samples are counted, and that a
// foreground or presentation lapse stays visible to a reader that differences
// two published snapshots.
import Testing

@testable import TerminalBenchmarkCoverage

struct TerminalBenchmarkPresentationCoverageRecorderTests {
    @Test("A fresh recorder counts nothing, so an unsampled interval cannot read as covered")
    func freshRecorderHasNoSamples() {
        // Intent: before any sample is taken every counter is zero.
        // Why it exists: the reader's proof of coverage is a positive sample delta, so a
        //   recorder that started at a nonzero count would let an interval nobody sampled
        //   claim it was covered.
        let recorder = TerminalBenchmarkPresentationCoverageRecorder()
        #expect(recorder.sampleCount == 0)
        #expect(recorder.foregroundSampleCount == 0)
        #expect(recorder.presentedSampleCount == 0)
    }

    @Test("Every sample with the app foreground and its window presented counts in all three totals")
    func coveredSamplesAdvanceEveryCounter() {
        // Intent: a sample taken while the app is active and its window presented advances
        //   the total, the foreground total, and the presented total together.
        // Why it exists: the reader proves coverage by comparing the foreground and
        //   presented deltas against the total delta; equality is only meaningful if a
        //   fully covered sample really advances all three.
        var recorder = TerminalBenchmarkPresentationCoverageRecorder()
        for _ in 0..<3 {
            recorder.record(isForeground: true, isPresented: true)
        }
        #expect(recorder.sampleCount == 3)
        #expect(recorder.foregroundSampleCount == 3)
        #expect(recorder.presentedSampleCount == 3)
    }

    @Test("A foreground lapse still counts as a sample, so the reader sees the gap")
    func foregroundLapseIsCountedAsAnUncoveredSample() {
        // Intent: losing foreground while the window stays presented advances the total and
        //   the presented total but not the foreground total.
        // Why it exists: a lapse that skipped the total too would be indistinguishable from
        //   a publisher that simply stopped sampling, and the capture would be rejected for
        //   the wrong reason -- or, worse, read as uninterrupted.
        var recorder = TerminalBenchmarkPresentationCoverageRecorder()
        recorder.record(isForeground: true, isPresented: true)
        recorder.record(isForeground: false, isPresented: true)
        #expect(recorder.sampleCount == 2)
        #expect(recorder.foregroundSampleCount == 1)
        #expect(recorder.presentedSampleCount == 2)
    }

    @Test("A presentation lapse is counted independently of foreground")
    func presentationLapseIsCountedIndependently() {
        // Intent: a window that is occluded, hidden, or off-screen while the app remains
        //   active advances the total and the foreground total but not the presented total.
        // Why it exists: the two conditions fail separately -- a covering window leaves the
        //   app active -- so one counter for both would hide the presentation lapse that
        //   invalidates the capture.
        var recorder = TerminalBenchmarkPresentationCoverageRecorder()
        recorder.record(isForeground: true, isPresented: false)
        #expect(recorder.sampleCount == 1)
        #expect(recorder.foregroundSampleCount == 1)
        #expect(recorder.presentedSampleCount == 0)
    }

    @Test("The artifact publishes the three cumulative counters a reader differences")
    func artifactPublishesCumulativeCounters() {
        // Intent: `artifact()` emits exactly the three cumulative totals, under the keys the
        //   activity snapshot reader looks for.
        // Why it exists: the published keys are the contract between this recorder and the
        //   profiling harness that subtracts two snapshots; renaming or dropping one would
        //   silently turn a measured interval into an unprovable one.
        var recorder = TerminalBenchmarkPresentationCoverageRecorder()
        recorder.record(isForeground: true, isPresented: true)
        recorder.record(isForeground: false, isPresented: false)
        let artifact = recorder.artifact()
        #expect(Set(artifact.keys) == [
            "sampleCount",
            "foregroundSampleCount",
            "presentedSampleCount",
        ])
        #expect(artifact["sampleCount"] as? Int == 2)
        #expect(artifact["foregroundSampleCount"] as? Int == 1)
        #expect(artifact["presentedSampleCount"] as? Int == 1)
    }
}
