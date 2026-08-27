# shellcheck shell=bash
# One shape for "this lint found its subject". Source this; it defines no state beyond
# the array `lint_resolve_targets` fills.
#
# A lint that names its subject as a path is a lint that a rename can silently disarm.
# `rg` exits non-zero on a path it cannot read, and the idiomatic `if rg ...; then fail;
# fi` reads any non-zero status as "no violations", so the gate prints its success line
# over nothing at all. `find` in a process substitution loses its status the same way.
# The gate discards a passing step's output, so not even the search tool's complaint on
# stderr survives to tell anyone.
#
# Existence alone is not the property worth having. A lint whose target is a directory
# survives a rename of the directory's contents: the path still resolves, the sweep
# matches no file, and the lint reports "passed". So the check is on the file list the
# lint is about to read, not on the names it was handed. After `lint_resolve_targets`
# returns, "the lint reported passed" means it read at least one file.

# Bails out of a lint that could not read what it was pointed at. Takes one line of
# detail per unreadable target, so a run names every path that moved rather than only
# the first.
#
# Deliberately does NOT print the rule's rationale: nothing was checked, so nothing was
# violated, and the rule's prose would only send the reader looking for a violation that
# does not exist. What they need is the path.
lint_checked_nothing() {
    local lint="$1"
    shift
    local detail
    for detail in "$@"; do
        echo "$lint: $detail" >&2
    done
    echo "  this lint checked nothing. Point it at the moved path, or update the path here." >&2
    exit 1
}

# Fails unless every named path exists as a file or a directory.
#
# For a lint that reads named files directly rather than sweeping a list. A caller that
# sweeps wants `lint_resolve_targets`, which subsumes this and also rejects a target that
# resolves to no file.
lint_require_targets() {
    local lint="$1"
    shift
    local path
    local missing=()
    for path in "$@"; do
        [[ -e "$path" ]] || missing+=("no such file or directory: $path")
    done
    [[ "${#missing[@]}" -eq 0 ]] || lint_checked_nothing "$lint" "${missing[@]}"
}

# Expands the named targets into the files a lint is about to sweep, in `LINT_TARGET_FILES`.
#
# A named file is a target as given; a named directory contributes every file under it
# matching `pattern`. Fails when a name does not resolve, and again when the whole list
# comes out empty -- the case an existence check cannot see.
lint_resolve_targets() {
    local lint="$1" pattern="$2"
    shift 2
    lint_require_targets "$lint" "$@"
    LINT_TARGET_FILES=()
    local path file
    for path in "$@"; do
        if [[ -f "$path" ]]; then
            LINT_TARGET_FILES+=("$path")
        else
            # No -L: app/DanTermCore and app/DanTermSupport are symlinks into lib/, and
            # following them would sweep the same file under two names.
            while IFS= read -r file; do
                LINT_TARGET_FILES+=("$file")
            done < <(find "$path" -type f -name "$pattern" | sort)
        fi
    done
    if [[ "${#LINT_TARGET_FILES[@]}" -eq 0 ]]; then
        lint_checked_nothing "$lint" "no $pattern file under: $*"
    fi
}
