// UI-harness coverage for `observeOnMain`, the app's only NotificationCenter
// block-observer registration. The two properties every caller inherits from it
// are checked here -- the body runs on the main thread, and it runs in the same
// pass as a main-thread post -- so the five call sites do not each need a test.
import Cocoa

/// Mutable state a notification body writes and the test reads afterwards, in a
/// reference the body can capture without the harness caring about isolation.
private final class ObserverProbe {
    var runCount = 0
    var ranOnMainThread = true
}

@MainActor
func observeOnMainTests() {
    print("observeOnMain")

    uiTest("body runs in the same pass as a main-thread post") {
        // Intent: after `post` returns on the main thread, the body has
        //   already run -- no main-actor turn separates the two.
        // Why it exists: the scroller-style observer forces overlay scrollers
        //   back on, and the override has to land in the pass that produced the
        //   notification or the legacy scrollers get a turn to draw. An
        //   implementation that hopped through `Task { @MainActor in }` would
        //   still be main-actor and still look correct at every call site.
        let name = Notification.Name("danterm.observeOnMain.samePass")
        let probe = ObserverProbe()
        let token = observeOnMain(name) { probe.runCount += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        NotificationCenter.default.post(name: name, object: nil)

        try uiExpect(probe.runCount == 1,
                     "body ran \(probe.runCount) times by the time post returned, expected 1")
    }

    uiTest("body runs on the main thread when posted from a background thread") {
        // Intent: a notification posted off the main thread still runs its
        //   body on the main thread.
        // Why it exists: this is the guarantee the main-actor bodies depend on.
        //   A registration that let the body run on the poster's thread would
        //   touch AppKit state from a background thread.
        let name = Notification.Name("danterm.observeOnMain.background")
        let probe = ObserverProbe()
        let token = observeOnMain(name) {
            probe.ranOnMainThread = Thread.isMainThread
            probe.runCount += 1
        }
        defer { NotificationCenter.default.removeObserver(token) }

        DispatchQueue.global().async {
            NotificationCenter.default.post(name: name, object: nil)
        }

        let deadline = Date().addingTimeInterval(5)
        while probe.runCount == 0, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }

        try uiExpect(probe.runCount == 1, "body never ran for a background post")
        try uiExpect(probe.ranOnMainThread, "body ran off the main thread")
    }

    uiTest("only notifications matching the object filter reach the body") {
        // Intent: the `object` argument still narrows delivery to one poster.
        // Why it exists: four of the five call sites filter on a specific
        //   scroll view or text view, so a helper that dropped the filter would
        //   fan every pane's scroll notifications into every other pane.
        let name = Notification.Name("danterm.observeOnMain.filter")
        let wanted = NSObject()
        let other = NSObject()
        let probe = ObserverProbe()
        let token = observeOnMain(name, object: wanted) { probe.runCount += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        NotificationCenter.default.post(name: name, object: other)
        try uiExpect(probe.runCount == 0, "body ran for a notification from another object")

        NotificationCenter.default.post(name: name, object: wanted)
        try uiExpect(probe.runCount == 1, "body did not run for the observed object")
    }
}
