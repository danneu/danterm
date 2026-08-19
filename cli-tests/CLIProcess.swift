// Runs the built `danterm` executable as a subprocess and reports what a caller of the
// shell would see: exit status, stdout, stderr.
//
// This is the launching machinery only, shared by every black-box test file in this
// target. No assertion and no knowledge of any particular command belongs here -- a test
// that needs a scripted control endpoint builds one beside its own cases.
import Foundation

/// Locates the test bundle so the CLI executable beside it can be found. `Bundle.main`
/// under `swift test` points at the toolchain's test helper, not at the build products.
private final class BuildProductsAnchor: NSObject {}

/// One finished run of the `danterm` executable, as a caller of the shell would see it.
struct CLIRun {
    let status: Int32
    let stdout: String
    let stderr: String
}

/// The build-products copy of the CLI, which is the same binary the app bundle carries.
func cliExecutableURL() -> URL {
    Bundle(for: BuildProductsAnchor.self)
        .bundleURL
        .deletingLastPathComponent()
        .appendingPathComponent("DanTermCLI")
}

func runCLI(_ arguments: [String], socketPath: String) throws -> CLIRun {
    try runCLI(arguments, environment: ["DANTERM_SOCK": socketPath])
}

func runCLI(_ arguments: [String], environment: [String: String]) throws -> CLIRun {
    let process = Process()
    process.executableURL = cliExecutableURL()
    process.arguments = arguments
    process.environment = environment.merging(["PATH": "/usr/bin:/bin"]) { current, _ in current }
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    try process.run()
    // Read both pipes before waiting: a reply larger than one pipe buffer would
    // otherwise block the child on write while this thread blocks on exit.
    let outData = out.fileHandleForReading.readDataToEndOfFile()
    let errData = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return CLIRun(
        status: process.terminationStatus,
        stdout: String(decoding: outData, as: UTF8.self),
        stderr: String(decoding: errData, as: UTF8.self)
    )
}
