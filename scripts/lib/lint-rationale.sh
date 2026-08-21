# shellcheck shell=bash
# One shape for the explanation a failing gate lint owes its reader. Source this; it
# defines no state.
#
# A lint's rationale usually lives in the header comment of the lint script, where a
# human reading the source finds it. That is the wrong place for the only copy: the
# reader who actually needs it is whoever just tripped the gate, and what they see is
# stderr. A message that reports only what was measured -- "expected one call, found
# two" -- tells them a rule exists without telling them which rule, so the cheapest way
# out looks like deleting the second call rather than understanding why there is one.
#
# So a failing lint prints two things: the violation, and why the rule exists plus what
# to do instead. `lint_rationale` is the second half.
#
# It refuses an empty body rather than printing an empty box. Every lint's self-test
# exercises its failure path, so a rationale someone forgot to write fails that test
# instead of shipping as a blank frame.

# Prints a fenced block of prose to stderr, for a lint that is about to exit non-zero.
#
# Takes the body on stdin, normally as a quoted heredoc. Keep it to what the reader
# cannot recover on their own: the rule's purpose, the shape that satisfies it, and a
# doc path when one exists. The per-violation detail belongs above this block, not in
# it -- this text is the same on every failure.
lint_rationale() {
    local body
    body="$(cat)"
    if [[ -z "${body//[[:space:]]/}" ]]; then
        echo "lint-rationale: a failing lint must explain itself; the body was empty" >&2
        exit 70
    fi
    {
        echo
        echo "======================================================================="
        printf '%s\n' "$body"
        echo "======================================================================="
    } >&2
}
