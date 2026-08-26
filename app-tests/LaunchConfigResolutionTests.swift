// Behavioral coverage for the one place a launch decides which config file the
// process owns. Everything downstream is handed that value, so these cases are the
// whole contract: the given file, the standard file, or a refused launch.
import Foundation
import Testing
@testable import DanTerm

struct LaunchConfigResolutionTests {
    @Test("a config argument names the file the process owns")
    func configArgumentNamesTheOwnedFile() throws {
        let url = try resolveLaunchConfigURL(
            arguments: ["DanTerm", launchConfigArgument, "/slots/3/config.json"],
            home: "/fixture-home"
        )

        #expect(url.path == "/slots/3/config.json")
    }

    @Test("no config argument resolves the standard per-user file")
    func absentArgumentResolvesTheStandardFile() throws {
        // Intent: production launches with no argument keep reading the file the
        //   user edits and the home-manager module writes.
        // Why it exists: the explicit argument exists for slots and harnesses; the
        //   ordinary launch must not change which file it owns.
        // Scenario: the shipped app starts from the Dock with no arguments beyond
        //   its own executable path.
        let url = try resolveLaunchConfigURL(arguments: ["DanTerm"], home: "/fixture-home")

        #expect(url.path == "/fixture-home/.config/danterm/config.json")
    }

    @Test("a config argument with no value refuses the launch")
    func missingValueRefusesTheLaunch() {
        // Intent: an argument that names nothing fails instead of falling back.
        // Why it exists: a silent fallback would hand a harness or a pool slot the
        //   user's own config file, which is the defect the argument removes.
        // Scenario: a launcher builds its argument list and the path expands to
        //   nothing, leaving `--config` as the final token.
        #expect(throws: LaunchConfigArgumentError.missingValue) {
            try resolveLaunchConfigURL(arguments: ["DanTerm", launchConfigArgument], home: "/h")
        }
        #expect(throws: LaunchConfigArgumentError.missingValue) {
            try resolveLaunchConfigURL(
                arguments: ["DanTerm", launchConfigArgument, ""],
                home: "/h"
            )
        }
        #expect(throws: LaunchConfigArgumentError.missingValue) {
            try resolveLaunchConfigURL(
                arguments: ["DanTerm", launchConfigArgument, "--fresh"],
                home: "/h"
            )
        }
    }

    @Test("a repeated config argument refuses the launch")
    func repeatedArgumentRefusesTheLaunch() {
        // Intent: two answers to "which config file is this" is no answer.
        // Why it exists: picking either one silently would make the owned file
        //   depend on argument order rather than on what the launch said.
        // Scenario: a wrapper script adds its own `--config` to a command line that
        //   already carried one.
        #expect(throws: LaunchConfigArgumentError.repeated) {
            try resolveLaunchConfigURL(
                arguments: ["DanTerm", launchConfigArgument, "/a.json", launchConfigArgument, "/b.json"],
                home: "/h"
            )
        }
    }
}
