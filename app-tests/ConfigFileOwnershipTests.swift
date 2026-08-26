// Coverage for the property the launch-resolved config file exists to establish:
// an instance reads the file it was given and no other. Path resolution itself is
// covered in LaunchConfigResolutionTests; this file is about what a running runtime
// then does with the file it owns.
import Foundation
import Testing
@testable import DanTerm

@MainActor
struct ConfigFileOwnershipTests {
    /// Writes one config document per test and removes the whole tree afterwards.
    private struct ConfigFiles {
        let rootURL: URL

        init() throws {
            rootURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("dt-config-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        }

        func write(name: String, fontSize: Int) throws -> URL {
            let url = rootURL.appendingPathComponent(name)
            try Data(#"{"schemaVersion":1,"font":{"size":\#(fontSize)}}"#.utf8).write(to: url)
            return url
        }

        func remove() {
            try? FileManager.default.removeItem(at: rootURL)
        }
    }

    @Test("two instances given different config files each resolve their own font")
    func separateConfigFilesDoNotInterfere() throws {
        // Intent: the font an instance runs at comes from the config file that
        //   instance was given, so two instances can run different settings at once.
        // Why it exists: this is the whole point of naming the config file at
        //   launch -- a harness comparing two font sizes, and a pool slot that must
        //   not inherit the settings of the instance beside it.
        // Scenario: an agent launches two instances with two config files that name
        //   different font sizes.
        let files = try ConfigFiles()
        defer { files.remove() }
        let smallURL = try files.write(name: "small.json", fontSize: 11)
        let largeURL = try files.write(name: "large.json", fontSize: 19)

        let smallPorts = RecordingAppRuntimePorts()
        let small = makeCommandTestRuntime(smallPorts, configStore: DanTermConfigStore(url: smallURL))
        defer { small.shutdown() }
        let largePorts = RecordingAppRuntimePorts()
        let large = makeCommandTestRuntime(largePorts, configStore: DanTermConfigStore(url: largeURL))
        defer { large.shutdown() }

        #expect(small.model.config.fontSize == 11)
        #expect(large.model.config.fontSize == 19)
    }
}
