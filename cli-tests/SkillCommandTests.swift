// Filesystem coverage for the local `danterm skill` resource loader.
import Foundation
import Testing
@testable import DanTermCLI

struct SkillCommandTests {
    @Test("skill loader follows an executable symlink into its app bundle")
    func symlinkedExecutableLoadsBundledSkill() throws {
        let fixture = try SkillBundleFixture()
        defer { fixture.remove() }

        let data = try loadBundledSkill(
            argv0: fixture.symlink.path,
            environment: ["PATH": fixture.binDirectory.path],
            fileManager: .default
        )

        #expect(data == fixture.skillData)
    }

    @Test("skill loader reports a missing bundled resource")
    func missingResourceFailsCleanly() throws {
        let fixture = try SkillBundleFixture(includeSkill: false)
        defer { fixture.remove() }

        #expect(throws: SkillCommandError.resourceUnavailable) {
            try loadBundledSkill(
                argv0: fixture.executable.path,
                environment: [:],
                fileManager: .default
            )
        }
    }
}

private struct SkillBundleFixture {
    let root: URL
    let executable: URL
    let binDirectory: URL
    let symlink: URL
    let skillData = Data("fixture skill\n".utf8)

    init(includeSkill: Bool = true) throws {
        let fileManager = FileManager.default
        root = fileManager.temporaryDirectory
            .appendingPathComponent("danterm-skill-\(UUID().uuidString)", isDirectory: true)
        executable = root.appendingPathComponent("DanTerm.app/Contents/Helpers/danterm")
        binDirectory = root.appendingPathComponent("bin", isDirectory: true)
        symlink = binDirectory.appendingPathComponent("danterm")

        try fileManager.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: executable)
        try fileManager.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: symlink, withDestinationURL: executable)

        if includeSkill {
            let resource = root
                .appendingPathComponent("DanTerm.app/Contents/Resources/danterm/SKILL.md")
            try fileManager.createDirectory(
                at: resource.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try skillData.write(to: resource)
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
