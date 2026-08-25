#!/usr/bin/env bash
# Self-test for the external corpus ledger lint. Every case builds a fixture tree
# and asserts the exit status, so the lint is pinned in both directions -- a lint
# that rejected everything would satisfy the negative cases alone and then reject
# the first legitimate ledger.
#
# The failure the lint exists for is I4, the unweighed file: the incident it was
# written after left thirteen of sixteen files out of the manifest, and nothing
# noticed for a month because an absent file and a file with nothing worth taking
# look identical. I2 and I3 are the same failure at case granularity, in each
# direction. The skip case matters as much as any of them: `references/` is
# gitignored, so a fresh clone and CI have no checkout, and a completeness lint
# that reported success after reading nothing would be worse than absent.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LINT="$SCRIPT_DIR/../external-corpus-ledger-lint.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
passes() { python3 "$LINT" "$1" >/dev/null 2>&1; }
expect_pass() { passes "$1" || fail "$2"; }
expect_fail() { ! passes "$1" || fail "$2"; }

PIN="1cea42d433253d95c4487a3037db48197b5e72f4"
MANIFEST_REL="lib/TerminalCore/Tests/TerminalCoreTests/Fixtures/windows-terminal-manifest.json"
UT_REL="references/windows-terminal/src/terminal/parser/ut_parser/ExampleTest.cpp"
REFLOW_REL="references/windows-terminal/src/buffer/out/ut_textbuffer/ReflowTests.cpp"

# Build a complete, passing tree: two upstream files, one of them the table-driven
# ReflowTests whose scenarios are the unit the ledger records.
build_valid() {
    local root="$1"
    mkdir -p "$root/scripts" "$root/$(dirname "$MANIFEST_REL")" \
        "$root/$(dirname "$UT_REL")" "$root/$(dirname "$REFLOW_REL")"

    cat > "$root/scripts/fetch-references.py" <<EOF
Reference(
    name="windows-terminal",
    url="https://github.com/microsoft/terminal.git",
    pin="$PIN",
)
EOF

    cat > "$root/$UT_REL" <<'EOF'
class ExampleTest
{
    TEST_METHOD(AlphaTest);
    TEST_METHOD(BetaTest);
};
EOF

    # Twelve leading spaces and a trailing comma is the shape the scenario table
    # uses upstream; the lint keys on it, so the fixture must reproduce it exactly.
    cat > "$root/$REFLOW_REL" <<'EOF'
    TEST_METHOD(TestReflowCases);
    static const TestCase testCases[] = {
        {
            L"No reflow required",
        },
        {
            L"SBCS, cursor remains in buffer",
        },
    };
EOF

    cat > "$root/$MANIFEST_REL" <<EOF
{
  "version": 1,
  "pinnedCommit": "$PIN",
  "recordedDeviations": [],
  "files": [
    {
      "path": "src/terminal/parser/ut_parser/ExampleTest.cpp",
      "licenseNotice": "LICENSE.windows-terminal.txt",
      "cases": [
        { "name": "AlphaTest", "disposition": "superseded", "rationale": "covered" },
        { "name": "BetaTest", "disposition": "out-of-scope", "rationale": "absent" }
      ]
    },
    {
      "path": "src/buffer/out/ut_textbuffer/ReflowTests.cpp",
      "licenseNotice": "LICENSE.windows-terminal.txt",
      "cases": [
        { "name": "No reflow required", "disposition": "superseded", "rationale": "covered" },
        { "name": "SBCS, cursor remains in buffer", "disposition": "superseded", "rationale": "covered" }
      ]
    }
  ]
}
EOF
}

# --- Baseline: a complete ledger passes. ---
BASE="$TMP/valid"
build_valid "$BASE"
expect_pass "$BASE" "a complete ledger must pass"

# --- I4: a file present upstream with no manifest entry. ---
# This is the incident the lint was written after.
CASE="$TMP/missing-file"
build_valid "$CASE"
python3 - "$CASE/$MANIFEST_REL" <<'EOF'
import json, sys
path = sys.argv[1]
m = json.load(open(path))
m["files"] = [f for f in m["files"] if "ReflowTests" not in f["path"]]
json.dump(m, open(path, "w"))
EOF
expect_fail "$CASE" "a file absent from the ledger must fail"

# --- I2: a case present upstream with no disposition. ---
CASE="$TMP/missing-case"
build_valid "$CASE"
python3 - "$CASE/$MANIFEST_REL" <<'EOF'
import json, sys
path = sys.argv[1]
m = json.load(open(path))
for f in m["files"]:
    f["cases"] = [c for c in f["cases"] if c["name"] != "BetaTest"]
json.dump(m, open(path, "w"))
EOF
expect_fail "$CASE" "an unclassified case must fail"

# --- I3: a manifest entry naming a case that does not exist upstream. ---
# A phantom entry hides a real gap by inflating the count, so it is an error
# rather than a harmless extra.
CASE="$TMP/phantom-case"
build_valid "$CASE"
python3 - "$CASE/$MANIFEST_REL" <<'EOF'
import json, sys
path = sys.argv[1]
m = json.load(open(path))
m["files"][0]["cases"].append(
    {"name": "GhostTest", "disposition": "superseded", "rationale": "x"}
)
json.dump(m, open(path, "w"))
EOF
expect_fail "$CASE" "a phantom case entry must fail"

# --- I3: a manifest entry for a file that holds no cases at this pin. ---
CASE="$TMP/phantom-file"
build_valid "$CASE"
python3 - "$CASE/$MANIFEST_REL" <<'EOF'
import json, sys
path = sys.argv[1]
m = json.load(open(path))
m["files"].append(
    {
        "path": "src/terminal/parser/ut_parser/GoneTest.cpp",
        "licenseNotice": "LICENSE.windows-terminal.txt",
        "cases": [{"name": "X", "disposition": "superseded", "rationale": "x"}],
    }
)
json.dump(m, open(path, "w"))
EOF
expect_fail "$CASE" "a manifest entry for an absent file must fail"

# --- I1: the ledger's pin does not match the fetched pin. ---
# Checked even without a checkout, because it is answerable from the repo alone.
CASE="$TMP/stale-pin"
build_valid "$CASE"
python3 - "$CASE/$MANIFEST_REL" <<'EOF'
import json, sys
path = sys.argv[1]
m = json.load(open(path))
m["pinnedCommit"] = "0" * 40
json.dump(m, open(path, "w"))
EOF
expect_fail "$CASE" "a stale pinnedCommit must fail"

CASE="$TMP/stale-pin-no-refs"
build_valid "$CASE"
rm -rf "$CASE/references"
python3 - "$CASE/$MANIFEST_REL" <<'EOF'
import json, sys
path = sys.argv[1]
m = json.load(open(path))
m["pinnedCommit"] = "0" * 40
json.dump(m, open(path, "w"))
EOF
expect_fail "$CASE" "a stale pinnedCommit must fail even with no checkout"

# --- The skip: no checkout means the completeness invariants are unanswerable. ---
# It must exit 0 rather than reporting a clean ledger it never read.
CASE="$TMP/no-references"
build_valid "$CASE"
rm -rf "$CASE/references"
expect_pass "$CASE" "an absent checkout must skip, not fail"
python3 "$LINT" "$CASE" | grep -q "skipped" \
    || fail "the skip must say the completeness invariants were not checked"

# --- An incomplete ledger with no checkout must still skip, not silently pass. ---
# This is the case that would have hidden the original incident in CI. The lint
# cannot catch it there; the test pins that it says so rather than claiming
# success.
CASE="$TMP/incomplete-no-references"
build_valid "$CASE"
rm -rf "$CASE/references"
python3 - "$CASE/$MANIFEST_REL" <<'EOF'
import json, sys
path = sys.argv[1]
m = json.load(open(path))
m["files"] = []
json.dump(m, open(path, "w"))
EOF
python3 "$LINT" "$CASE" | grep -q "skipped" \
    || fail "an incomplete ledger with no checkout must report a skip, not completeness"

echo "external-corpus-ledger-lint self-test passed"
