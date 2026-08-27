#!/usr/bin/env bash
# Keep the two engine packages consumable as versioned dependencies.
#
# `lib/TerminalCore` and `lib/TerminalPTY` are the reusable half of this repository: the
# grid, parser, and renderer, plus the process lifecycle. They are meant to be published,
# so somebody outside this tree can name one as a SwiftPM dependency. A manifest can
# forfeit that quietly, and this gate covers the one way it already did.
#
# `.unsafeFlags` is the forfeit. SwiftPM refuses a target that declares it whenever the
# package is reached as a versioned dependency, so the manifest resolves only for a path
# dependency -- which is to say, only inside this repository. `lib/TerminalCore` carried a
# type-check budget that way for a week, and nothing said so: every consumer in the tree is
# a path dependency, so every build stayed green while the package was unpublishable. The
# flags now live in `scripts/type-check-budget-gate.sh`, which is where a development-only
# measurement belongs, and this gate is what stops them coming back.
#
# Scope is the two packages the reuse story intends to publish, not every first-party
# manifest. `.unsafeFlags` in a manifest nobody outside this repository can reach costs
# nothing, and the root package uses none today anyway.
#
# It takes no arguments: the manifests it reads are the rule, so naming one on the command
# line would let a caller pick which half of the rule to run. The self-test points the root
# at a fixture tree instead, which proves each verdict without the real tree.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/lint-rationale.sh
source "$SCRIPT_DIR/lib/lint-rationale.sh"
# shellcheck source=lib/lint-targets.sh
source "$SCRIPT_DIR/lib/lint-targets.sh"

# Test seam: the self-test points the sweep at a fixture tree so the missing-manifest check
# and both verdicts are proven without the real tree. Nothing else sets this.
ROOT="${ENGINE_PUBLISHABLE_LINT_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# Root-relative, because the packages named here are the ones the mirror will hold. Adding
# a third engine package to the reuse story means adding it here too.
MANIFESTS=(
    'lib/TerminalCore/Package.swift'
    'lib/TerminalPTY/Package.swift'
)

# A manifest this gate cannot find is not a manifest it can vouch for, so a rename must fail
# here rather than let the sweep report success over nothing.
targets=()
for entry in "${MANIFESTS[@]}"; do
    targets+=("$ROOT/$entry")
done
lint_require_targets "engine-publishable-lint" "${targets[@]}"

# A commented-out line is prose about the rule, not a declaration SwiftPM reads, so the
# manifest may keep the history of what it used to carry.
set +e
violations="$(rg --pcre2 -n '^(?![[:space:]]*//).*\bunsafeFlags\b' "${targets[@]}")"
status=$?
set -e

# `rg` exits 1 on a clean scan and 2 on a failure of its own. Folding the two together
# would report a broken pattern as a passing gate.
if [[ "$status" -gt 1 ]]; then
    echo "engine-publishable-lint: rg failed with status $status" >&2
    exit 1
fi

if [[ "$status" -eq 0 ]]; then
    printf '%s\n' "$violations" >&2
    lint_rationale <<'EOF'
engine-publishable lint FAILED: an engine manifest declares `unsafeFlags`.

SwiftPM refuses a target carrying `unsafeFlags` whenever the package is
reached as a versioned dependency. `lib/TerminalCore` and `lib/TerminalPTY`
are meant to be published, so a manifest that declares it can only ever be
consumed by path -- and every consumer in this repository is a path
dependency, so nothing else in the gate would notice.

Move the flags to whatever enforces them. A setting that exists to develop
the package -- a diagnostic budget, an experimental frontend flag -- is not
something a consumer's build should carry, so it belongs in the script that
reads the result. `scripts/type-check-budget-gate.sh` is the worked example:
it appends the frontend flags to the build command it wraps and turns a
breach into a red step.

If the setting really is a property of the built code rather than of
developing it, express it as a supported `SwiftSetting` instead. See "The
type-check budget on `lib/TerminalCore`" in agent-docs/build-details.md.
EOF
    exit 1
fi

echo "engine publishable lint passed"
