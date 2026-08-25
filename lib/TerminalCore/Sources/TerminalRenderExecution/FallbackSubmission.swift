// The dynamic scope that makes the CTLine fallback's submission to CoreText observable.
//
// It exists because the presentation rule in `drawTextCell` has no pixel-level evidence on
// macOS: bare U+23FA and U+23FA U+FE0E resolve to the same text face here, so a bitmap
// cannot tell whether the rule ran. The submitted scalar sequence is the observable that
// can, and it is the only thing this file exposes -- what CoreText then does with the
// sequence stays a property of the host.

/// Reports every string the `CTLine` fallback hands CoreText while `body` runs.
///
/// Task-local rather than a parameter or a stored property: the executor draws through free
/// functions on a caller-owned `CGContext`, so an observer would otherwise have to widen the
/// public draw signature for every caller. A task-local reaches the fallback without that,
/// and without the shared mutable state a module-scope box would race on under the gate's
/// parallel execution.
func withFallbackSubmissionObserver<Result>(
    _ observer: @escaping @Sendable (String) -> Void,
    do body: () throws -> Result
) rethrows -> Result {
    try FallbackSubmission.$observer.withValue(observer, operation: body)
}

/// The observer the fallback reports to, if any is installed for the current task.
enum FallbackSubmission {
    @TaskLocal static var observer: (@Sendable (String) -> Void)?
}
