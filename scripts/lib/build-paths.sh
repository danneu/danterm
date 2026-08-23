# Shared ownership rules for disposable build roots in a DanTerm checkout.

# Prints the absolute root that owns persistent gate and gate-adjacent build trees.
danterm_gate_build_root() {
    local repository_root="$1"
    (
        cd "$repository_root"
        printf '%s/.build-gate\n' "$PWD"
    )
}

# Prints one lane-specific path below the checkout's gate build root.
danterm_gate_build_path() {
    local repository_root="$1" descendant="$2"
    case "/$descendant/" in
        *//*|*/../*|*/./*)
            echo "build-paths: gate descendant must be a normalized relative path: $descendant" >&2
            return 1
            ;;
    esac
    [[ -n "$descendant" && "$descendant" != /* ]] || {
        echo "build-paths: gate descendant must be a normalized relative path: $descendant" >&2
        return 1
    }
    printf '%s/%s\n' "$(danterm_gate_build_root "$repository_root")" "$descendant"
}
