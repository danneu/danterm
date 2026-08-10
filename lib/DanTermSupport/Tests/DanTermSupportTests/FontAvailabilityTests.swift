// Swift Testing suite for DanTermSupport's font-availability probe and installed
// family catalog -- the CoreText side of `font.family`, which the pure core cannot
// answer. Covers what the config path depends on: a real family resolves, a typo
// does not, a PostScript face name canonicalizes to its family (so only a family
// ever reaches the render layer), and the catalog is a deduplicated list the
// Preferences combo box can present. The suite compiles under
// `swift test --package-path lib/DanTermSupport`, which is also the standing
// structural proof that Support names nothing in DanTermCore.
import Foundation
import Testing

@testable import DanTermSupport

@Suite struct FontAvailabilityTests {
    @Test("An installed family resolves to itself")
    func installedFamilyResolves() {
        // Intent: the happy path -- a family the machine has resolves to its
        //   canonical name so it can be handed to the render layer.
        // Why it exists: pins the probe's positive answer; without it the
        //   fallback-to-system-monospace path could swallow every family.
        // Scenario: a user sets "Menlo", which ships on every macOS.
        #expect(resolveInstalledFontFamily(named: "Menlo") == "Menlo")
    }

    @Test("A name no installed font carries does not resolve")
    func unknownFamilyDoesNotResolve() {
        // Intent: an unavailable name yields nil rather than a substituted face.
        // Why it exists: `CTFontCreateWithName` never fails -- it silently
        //   substitutes a last-resort face -- so a probe built on it alone would
        //   report every typo as installed and render the terminal proportionally
        //   with no signal.
        #expect(resolveInstalledFontFamily(named: "Fira Codee Not A Real Font") == nil)
    }

    @Test("Resolution is case- and whitespace-insensitive on the requested name")
    func resolutionNormalizesRequestedName() {
        #expect(resolveInstalledFontFamily(named: "  menlo  ") == "Menlo")
    }

    @Test("An empty or whitespace-only name does not resolve")
    func blankNameDoesNotResolve() {
        #expect(resolveInstalledFontFamily(named: "") == nil)
        #expect(resolveInstalledFontFamily(named: "   ") == nil)
    }

    @Test("A PostScript face name canonicalizes to its family, not to itself")
    func postScriptNameCanonicalizesToFamily() {
        // Intent: both the regular and the bold PostScript face of a family
        //   resolve to the family name.
        // Why it exists: pins I3's canonicalization rule. Passing "Menlo-Bold"
        //   through unchanged would make an already-bold face the terminal's base
        //   face and smuggle in the per-style font selection this schema
        //   deliberately excludes; bold and italic stay derived by the renderer.
        #expect(resolveInstalledFontFamily(named: "Menlo-Regular") == "Menlo")
        #expect(resolveInstalledFontFamily(named: "Menlo-Bold") == "Menlo")
    }

    @Test("The installed catalog lists each family once, sorted, with Menlo present")
    func catalogIsDeduplicatedAndSorted() {
        // Intent: the catalog is a presentable list -- no duplicate rows, a stable
        //   order, and no hidden system-internal entries.
        // Why it exists: the Preferences combo box shows this list directly, and a
        //   duplicate or unstable order is a visible defect there.
        let families = installedFontFamilyNames()

        #expect(families.contains("Menlo"))
        #expect(Set(families).count == families.count, "the catalog should not repeat a family")
        #expect(
            families == families.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending },
            "the catalog should be in a stable case-insensitive alphabetical order"
        )
        #expect(
            families.allSatisfy { $0.hasPrefix(".") == false },
            "hidden system-internal families should not be offered to the user"
        )
    }

    @Test("Every catalog entry resolves to itself")
    func catalogEntriesResolve() {
        // Intent: the two halves of the probe agree -- picking any name the
        //   catalog offers never produces the "not installed" warning.
        // Why it exists: guards the seam between the Preferences picker (commit 5)
        //   and the resolution that decides whether to warn; a mismatch would warn
        //   about a font the user just chose from the list.
        for family in installedFontFamilyNames() {
            #expect(resolveInstalledFontFamily(named: family) == family)
        }
    }
}
