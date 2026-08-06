#!/usr/bin/env bash
# Nearly every assertion hands a single-quoted snippet to `zsh -c` / `bash -c` /
# `fish -c`, and the whole point is that the *child* shell -- not this one --
# expands it. That is what SC2016 flags, at a dozen sites, so it is silenced for
# the file. Deliberately not blanket-silenced beyond that: an unexpanded `$` in
# a string this script consumes itself would still be a real bug.
# shellcheck disable=SC2016
set -euo pipefail

# The directory under test is an input so the same script can check the source
# tree (the default, for a local `just test`) and the Nix package output (what
# the flake check runs against). Every command below is resolved through PATH
# rather than an absolute path: a Linux Nix build sandbox has only /bin/sh, so
# an absolute /usr/bin/env, /bin/bash, or /usr/bin/expect would not exist there.
# Only /bin/sh -- used for the fake ssh/mosh shebangs -- stays absolute.
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
integration_dir="${DANTERM_INTEGRATION_DIR:-$repo_root/integrations/shell-integration}"

fail() {
    echo "shell-integration test failed: $*" >&2
    exit 1
}

assert_contains() {
    case "$1" in
        *"$2"*) ;;
        *) fail "expected output to contain: $2" ;;
    esac
}

assert_not_contains() {
    case "$1" in
        *"$2"*) fail "expected output not to contain: $2" ;;
        *) ;;
    esac
}

command_text='printf "hola 世界; $HOME"'
encoded_command="$(printf '%s' "$command_text" | base64 | tr -d '\n')"
encoded_user="$(printf '%s' 'user name' | base64 | tr -d '\n')"
encoded_host="$(printf '%s' 'host.example' | base64 | tr -d '\n')"
prefix="$(printf '\033]1337;DanTermShell=1;')"
terminator=$'\033\\'

for asset in danterm.zsh danterm.bash danterm.fish vendor/bash-preexec.sh vendor/bash-preexec.LICENSE vendor/bash-preexec.PROVENANCE; do
    test -f "$integration_dir/$asset" || fail "missing $asset"
done

# The documented rc hook chooses a local app-owned directory first, falls back
# to the packaged asset for a remote LC_DANTERM shell, and stays inert elsewhere.
# Keep these snippets in lockstep with hm-module.nix and README.md.
#
# Every case below pins DANTERM rather than inheriting it: the assets branch on
# it (a shell with DANTERM set is local, not remote), so an ambient value makes
# this block assert something different when run from inside DanTerm than from a
# Nix sandbox. That divergence is what shipped this block green locally and red
# in CI.
missing_integration="$integration_dir/missing"
for shell in zsh bash fish; do
    case "$shell" in
        zsh|bash)
            shell_args=()
            test "$shell" = zsh && shell_args=(-f)
            test "$shell" = bash && shell_args=(--noprofile --norc)
            local_output="$(env -u DANTERM DANTERM_SHELL_INTEGRATION_DIR="$integration_dir" "$shell" "${shell_args[@]}" -c '
                if [[ -n ${DANTERM_SHELL_INTEGRATION_DIR:-} ]]; then
                    asset=$DANTERM_SHELL_INTEGRATION_DIR/danterm.'"$shell"'
                    if [[ -r $asset ]]; then source "$asset"; else printf "DanTerm shell integration is unreadable: %s\\n" "$asset" >&2; fi
                elif [[ -n ${LC_DANTERM:-} ]]; then
                    source "$1/danterm.'"$shell"'"
                fi
                printf "%s" "${DANTERM_SHELL_INTEGRATION_DIR:-unset}"
            ' _ "$missing_integration" 2>&1)"
            inert_output="$(env -u DANTERM -u DANTERM_SHELL_INTEGRATION_DIR -u LC_DANTERM "$shell" "${shell_args[@]}" -c '
                if [[ -n ${DANTERM_SHELL_INTEGRATION_DIR:-} ]]; then source "$DANTERM_SHELL_INTEGRATION_DIR/danterm.'"$shell"'"; elif [[ -n ${LC_DANTERM:-} ]]; then source "$1/danterm.'"$shell"'"; fi
            ' _ "$missing_integration" 2>&1)"
            broken_output="$(env -u DANTERM DANTERM_SHELL_INTEGRATION_DIR="$missing_integration" "$shell" "${shell_args[@]}" -c '
                asset=$DANTERM_SHELL_INTEGRATION_DIR/danterm.'"$shell"'
                if [[ -r $asset ]]; then source "$asset"; else printf "DanTerm shell integration is unreadable: %s\\n" "$asset" >&2; fi
            ' 2>&1)"
            remote_output="$(env -u DANTERM -u DANTERM_SHELL_INTEGRATION_DIR LC_DANTERM=1 "$shell" "${shell_args[@]}" -c '
                if [[ -n ${DANTERM_SHELL_INTEGRATION_DIR:-} ]]; then
                    source "$DANTERM_SHELL_INTEGRATION_DIR/danterm.'"$shell"'"
                elif [[ -n ${LC_DANTERM:-} ]]; then
                    source "$1/danterm.'"$shell"'"
                fi
                printf loaded
            ' _ "$integration_dir")"
            ;;
        fish)
            local_output="$(env -u DANTERM DANTERM_SHELL_INTEGRATION_DIR="$integration_dir" fish --no-config -c '
                if set -q DANTERM_SHELL_INTEGRATION_DIR; and test -n "$DANTERM_SHELL_INTEGRATION_DIR"
                    set asset "$DANTERM_SHELL_INTEGRATION_DIR/danterm.fish"
                    if test -r "$asset"; source "$asset"; else; printf "DanTerm shell integration is unreadable: %s\\n" "$asset" >&2; end
                else if set -q LC_DANTERM; and test -n "$LC_DANTERM"
                    source $argv[1]/danterm.fish
                end
                printf %s "$DANTERM_SHELL_INTEGRATION_DIR"
            ' "$missing_integration" 2>&1)"
            inert_output="$(env -u DANTERM -u DANTERM_SHELL_INTEGRATION_DIR -u LC_DANTERM fish --no-config -c '
                if set -q DANTERM_SHELL_INTEGRATION_DIR; source $DANTERM_SHELL_INTEGRATION_DIR/danterm.fish; else if set -q LC_DANTERM; source $argv[1]/danterm.fish; end
            ' "$missing_integration" 2>&1)"
            broken_output="$(env -u DANTERM DANTERM_SHELL_INTEGRATION_DIR="$missing_integration" fish --no-config -c '
                set asset "$DANTERM_SHELL_INTEGRATION_DIR/danterm.fish"
                if test -r "$asset"; source "$asset"; else; printf "DanTerm shell integration is unreadable: %s\\n" "$asset" >&2; end
            ' 2>&1)"
            remote_output="$(env -u DANTERM -u DANTERM_SHELL_INTEGRATION_DIR LC_DANTERM=1 fish --no-config -c '
                if set -q DANTERM_SHELL_INTEGRATION_DIR; and test -n "$DANTERM_SHELL_INTEGRATION_DIR"
                    source $DANTERM_SHELL_INTEGRATION_DIR/danterm.fish
                else if set -q LC_DANTERM; and test -n "$LC_DANTERM"
                    source $argv[1]/danterm.fish
                end
                printf loaded
            ' "$integration_dir")"
            ;;
    esac
    test "$local_output" = "$integration_dir" || fail "$shell hook changed or lost the advertised directory"
    test -z "$inert_output" || fail "$shell hook was not inert outside DanTerm"
    assert_contains "$broken_output" "DanTerm shell integration is unreadable: $missing_integration/danterm.$shell"
    # Substring, not equality: a genuinely remote shell emits its `remote-host`
    # identity at source time, so that OSC legitimately precedes the marker. The
    # emission itself is asserted by the nested-ssh block at the end of the file;
    # here the only claim is that the packaged asset got sourced.
    case "$remote_output" in
        *loaded*) ;;
        *) fail "$shell remote fallback did not load packaged assets" ;;
    esac
done

for shell in zsh bash fish; do
    restore_file="$(mktemp)"
    printf 'restored scrollback' > "$restore_file"
    restore_command='printf first
printf second'
    case "$shell" in
        zsh)
            restore_output="$(DANTERM_RESTORE_SCROLLBACK_FILE="$restore_file" DANTERM_RESTORE_COMMAND="$restore_command" zsh -f -c 'source "$1/danterm.zsh"; [[ -z ${DANTERM_RESTORE_COMMAND+x} ]] || exit 34; printf "|%s" "$_danterm_restore_command"' _ "$integration_dir")"
            ;;
        bash)
            restore_output="$(DANTERM_RESTORE_SCROLLBACK_FILE="$restore_file" DANTERM_RESTORE_COMMAND="$restore_command" bash --noprofile --norc -c 'source "$1/danterm.bash"; [[ -z ${DANTERM_RESTORE_COMMAND+x} ]] || exit 34; printf "|unset"' _ "$integration_dir")"
            ;;
        fish)
            restore_output="$(env DANTERM_RESTORE_SCROLLBACK_FILE="$restore_file" DANTERM_RESTORE_COMMAND="$restore_command" fish --no-config -c 'source $argv[1]/danterm.fish; set -q DANTERM_RESTORE_COMMAND; and exit 34; printf "|%s" "$_danterm_restore_command"' "$integration_dir")"
            ;;
    esac
    if test "$shell" = bash; then
        expected_restore='restored scrollback|unset'
    else
        expected_restore="restored scrollback|$restore_command"
    fi
    test "$restore_output" = "$expected_restore" || fail "$shell did not consume restore values"
    test ! -e "$restore_file" || fail "$shell did not consume the scrollback file"
done

for shell in zsh fish; do
    command -v "$shell" >/dev/null 2>&1 || continue
    SHELL_UNDER_TEST="$shell" INTEGRATION_DIR="$integration_dir" expect <<'EXPECT' || fail "$shell did not seed restore command safely"
set timeout 15
set shell $env(SHELL_UNDER_TEST)
set integration $env(INTEGRATION_DIR)
set marker DANTERM_PREFILL_EXECUTED
set command "printf DANTERM_PREFILL_%s EXECUTED"

proc fail_expect {label reason} {
    puts stderr "shell-integration test failed: $::shell $label: $reason"
    exit 1
}

proc expect_exact {label pattern} {
    expect {
        -exact $pattern { return }
        timeout { fail_expect $label "timed out waiting for '$pattern'" }
        eof { fail_expect $label "shell exited while waiting for '$pattern'" }
    }
}

proc expect_exact_without_marker {label pattern marker} {
    expect {
        -exact $marker { fail_expect $label "command executed before Enter" }
        -exact $pattern { return }
        timeout { fail_expect $label "timed out waiting for '$pattern'" }
        eof { fail_expect $label "shell exited while waiting for '$pattern'" }
    }
}

proc expect_shell_eof {label} {
    expect {
        eof { return }
        timeout { fail_expect $label "timed out waiting for shell exit" }
    }
}

if {$shell eq "zsh"} {
    spawn env DANTERM_RESTORE_COMMAND=$command "PROMPT=DANTERM_PROMPT> " zsh -f
    expect_exact "first prompt" "DANTERM_PROMPT> "
    send -- "source $integration/danterm.zsh\r"
} else {
    spawn env DANTERM_RESTORE_COMMAND=$command fish_features=no-query-term fish_greeting= fish --no-config --init-command "function fish_prompt; printf 'DANTERM_PROMPT> '; end"
    expect {
        -glob "*fish could not read response to Primary Device Attribute query*" {
            fail_expect "first prompt" "terminal query timed out"
        }
        -exact "DANTERM_PROMPT> " {}
        timeout { fail_expect "first prompt" "timed out waiting for deterministic prompt" }
        eof { fail_expect "first prompt" "shell exited before deterministic prompt" }
    }
    send -- "source $integration/danterm.fish\r"
}
expect_exact "restore command prefill" $command
send -- "\014"
expect_exact_without_marker "restore command redraw" $command $marker
send -- "\r"
expect_exact "restore command execution" $marker
send -- "exit\r"
expect_shell_eof "shell exit"
EXPECT
done

zsh_output="$(DANTERM=1 zsh -f -c '
    source "$1/danterm.zsh"
    source "$1/danterm.zsh"
    [[ ${DANTERM:-} == 1 ]] || exit 31
    danterm_emit_command_start "$2"
    danterm_emit_command_end
    danterm_emit_remote_start
    danterm_emit_remote_host "user name" host.example
' _ "$integration_dir" "$command_text")"

bash_output="$(DANTERM=1 bash --noprofile --norc -c '
    old_prompt() { :; }
    PROMPT_COMMAND=old_prompt
    trap ":" DEBUG
    source "$1/danterm.bash"
    source "$1/danterm.bash"
    [[ ${DANTERM:-} == 1 ]] || exit 31
    [[ $PROMPT_COMMAND == *old_prompt* ]] || exit 32
    [[ $(trap -p DEBUG) == *":"* ]] || exit 33
    danterm_emit_command_start "$2"
    danterm_emit_command_end
    danterm_emit_remote_start
    danterm_emit_remote_host "user name" host.example
' _ "$integration_dir" "$command_text")"

fish_output="$(env DANTERM=1 fish --no-config -c '
    source $argv[1]/danterm.fish
    source $argv[1]/danterm.fish
    test "$DANTERM" = 1; or exit 31
    danterm_emit_command_start $argv[2]
    danterm_emit_command_end
    danterm_emit_remote_start
    danterm_emit_remote_host "user name" host.example
' "$integration_dir" "$command_text")"

expected="$prefix""command-start;$encoded_command$terminator$prefix""command-end$terminator$prefix""remote-start$terminator$prefix""remote-host;$encoded_user;$encoded_host$terminator"
test "$zsh_output" = "$expected" || fail "zsh protocol differs"
test "$bash_output" = "$expected" || fail "bash protocol differs"
test "$fish_output" = "$expected" || fail "fish protocol differs"
assert_not_contains "$expected" "$(printf '\033]0;')"

for shell in zsh bash fish; do
    case "$shell" in
        zsh)
            silent_output="$(env -u DANTERM -u LC_DANTERM zsh -f -c 'source "$1/danterm.zsh"; danterm_emit_command_end; danterm_emit_cwd' _ "$integration_dir")"
            ;;
        bash)
            silent_output="$(env -u DANTERM -u LC_DANTERM bash --noprofile --norc -c 'source "$1/danterm.bash"; danterm_emit_command_end; danterm_emit_cwd' _ "$integration_dir")"
            ;;
        fish)
            silent_output="$(env -u DANTERM -u LC_DANTERM fish --no-config -c 'source $argv[1]/danterm.fish; danterm_emit_command_end; danterm_emit_cwd' "$integration_dir")"
            ;;
    esac
    test -z "$silent_output" || fail "$shell integration emitted without a DanTerm marker"
done

zsh_hooks="$(DANTERM=1 zsh -f -c '
    old_hook() { :; }
    precmd_functions=(old_hook)
    source "$1/danterm.zsh"
    [[ " ${precmd_functions[*]} " == *" old_hook "* ]] || exit 32
    _danterm_preexec "$2"
    _danterm_precmd
' _ "$integration_dir" "$command_text")"
bash_hooks="$(DANTERM=1 bash --noprofile --norc -c '
    source "$1/danterm.bash"
    _danterm_preexec "$2"
    _danterm_precmd
' _ "$integration_dir" "$command_text")"
fish_hooks="$(env DANTERM=1 fish --no-config -c '
    function old_handler --on-event fish_prompt; end
    source $argv[1]/danterm.fish
    functions -q old_handler; or exit 32
    emit fish_preexec $argv[2]
    emit fish_postexec 0
    emit fish_prompt
' "$integration_dir" "$command_text")"
osc133_a_full="$(printf '\033]133;A;redraw=1\007')"
osc133_a_last="$(printf '\033]133;A;redraw=last\007')"
osc133_b="$(printf '\033]133;B\007')"
osc133_p_i="$(printf '\033]133;P;k=i\007')"
osc133_c="$(printf '\033]133;C\007')"

for hook_output in "$zsh_hooks" "$bash_hooks" "$fish_hooks"; do
    assert_contains "$hook_output" "$prefix""command-start;$encoded_command$terminator"
    assert_contains "$hook_output" "$prefix""command-end$terminator"
    assert_contains "$hook_output" "$(printf '\033]7;file://')"
done
# zsh and Bash emit OSC 133 `C` themselves, immediately after the private
# envelope event so the mark sits adjacent to the command's own output. fish
# emits its own `C` and DanTerm adds none (docs/research/24-osc-133-dialect D4).
assert_contains "$zsh_hooks" "$prefix""command-start;$encoded_command$terminator$osc133_c"
assert_contains "$bash_hooks" "$prefix""command-start;$encoded_command$terminator$osc133_c"
assert_not_contains "$fish_hooks" "$osc133_c"
# fish's whole contribution is the redraw declaration, emitted per fish_prompt.
assert_contains "$fish_hooks" "$osc133_a_full"

# --- OSC 133 prompt marks ---------------------------------------------------
#
# The dialect's contract is one `prompt`-stamped row per prompt, restated on
# every prompt, surviving a prompt framework that installs its hooks after ours.
# These check the emitted bytes rather than the internals, so a mechanism change
# that still produces the dialect does not break them.

# zsh puts its marks inside PS1, because zsh re-emits PS1 in full on every
# redisplay -- that is what keeps the stamp alive across a SIGWINCH repaint.
zsh_prompt="$(DANTERM=1 zsh -f -c '
    PS1="%% "
    source "$1/danterm.zsh"
    _danterm_prompt_precmd
    printf "%s" "$PS1"
' _ "$integration_dir")"
assert_contains "$zsh_prompt" "$osc133_a_full"
assert_contains "$zsh_prompt" "$osc133_b"

# Running the hook again must not accumulate a second pair of marks. The
# unguarded "wrap whatever PS1 is now" form grows two marks per prompt forever.
zsh_prompt_twice="$(DANTERM=1 zsh -f -c '
    PS1="%% "
    source "$1/danterm.zsh"
    _danterm_prompt_precmd
    _danterm_prompt_precmd
    _danterm_prompt_precmd
    printf "%s" "$PS1"
' _ "$integration_dir")"
test "$zsh_prompt" = "$zsh_prompt_twice" || fail "zsh prompt wrap is not idempotent"

# A framework whose precmd is registered after ours would otherwise overwrite
# PS1 behind our back, silently: no marks, no diagnostic. We re-claim the tail.
zsh_tail="$(DANTERM=1 zsh -f -c '
    source "$1/danterm.zsh"
    late_framework_hook() { :; }
    add-zsh-hook precmd late_framework_hook
    _danterm_prompt_precmd
    printf "%s" "${precmd_functions[-1]}"
' _ "$integration_dir")"
test "$zsh_tail" = _danterm_prompt_precmd || fail "zsh hook did not re-claim the tail of precmd_functions"

# Bash prints `A` (fresh line + mode) and stamps the row from inside PS1 with
# `P`, which has no fresh-line behavior, because readline redisplays mid-line.
# `redraw=last` because readline repaints only the final line of the prompt.
bash_prompt="$(DANTERM=1 bash --noprofile --norc -c '
    PS1="bash$ "
    source "$1/danterm.bash"
    _danterm_prompt_command
    printf "%s" "$PS1"
' _ "$integration_dir")"
assert_contains "$bash_prompt" "$osc133_a_last"
assert_contains "$bash_prompt" "$osc133_p_i"
assert_contains "$bash_prompt" "$osc133_b"
assert_not_contains "$bash_prompt" "$osc133_a_full"
# The in-prompt marks must be wrapped in \[...\] or readline counts them toward
# the prompt width and mis-places the cursor on every line edit.
assert_contains "$bash_prompt" "$(printf '\\[\033]133;P;k=i\007\\]')"
assert_contains "$bash_prompt" "$(printf '\\[\033]133;B\007\\]')"

bash_prompt_twice="$(DANTERM=1 bash --noprofile --norc -c '
    PS1="bash$ "
    source "$1/danterm.bash"
    _danterm_prompt_command >/dev/null
    _danterm_prompt_command >/dev/null
    _danterm_prompt_command >/dev/null
    printf "%s" "$PS1"
' _ "$integration_dir")"
bash_prompt_once="$(DANTERM=1 bash --noprofile --norc -c '
    PS1="bash$ "
    source "$1/danterm.bash"
    _danterm_prompt_command >/dev/null
    printf "%s" "$PS1"
' _ "$integration_dir")"
test "$bash_prompt_once" = "$bash_prompt_twice" || fail "bash prompt wrap is not idempotent"

bash_tail="$(DANTERM=1 bash --noprofile --norc -c '
    source "$1/danterm.bash"
    PROMPT_COMMAND="${PROMPT_COMMAND}
late_framework_hook"
    _danterm_prompt_command >/dev/null
    printf "%s" "${PROMPT_COMMAND##*$'"'"'\n'"'"'}"
' _ "$integration_dir")"
test "$bash_tail" = _danterm_prompt_command || fail "bash hook did not re-claim the tail of PROMPT_COMMAND"

# With no DanTerm marker in the environment the dialect must be silent too --
# these scripts are sourced from a user's rc file and may run under any terminal.
for shell in zsh bash fish; do
    case "$shell" in
        zsh)
            quiet="$(env -u DANTERM -u LC_DANTERM zsh -f -c 'PS1="%% "; source "$1/danterm.zsh"; _danterm_prompt_precmd; printf "%s" "$PS1"' _ "$integration_dir")"
            ;;
        bash)
            quiet="$(env -u DANTERM -u LC_DANTERM bash --noprofile --norc -c 'PS1="bash$ "; source "$1/danterm.bash"; _danterm_prompt_command; printf "%s" "$PS1"' _ "$integration_dir")"
            ;;
        fish)
            quiet="$(env -u DANTERM -u LC_DANTERM fish --no-config -c 'source $argv[1]/danterm.fish; danterm_emit_prompt_redraw' "$integration_dir")"
            ;;
    esac
    assert_not_contains "$quiet" "$(printf '\033]133;')"
done

precedence_output="$(env DANTERM=1 LC_DANTERM=1 zsh -f -c '
    source "$1/danterm.zsh"
    danterm_emit_command_end
' _ "$integration_dir")"
test "$precedence_output" = "$prefix""command-end$terminator" || fail "local marker did not take precedence"

fake_bin="$(mktemp -d)"
trap 'rm -rf "$fake_bin"' EXIT
printf '#!/bin/sh\nprintf "SSH_ARGS=<%%s>\\n" "$*"\n' > "$fake_bin/ssh"
printf '#!/bin/sh\nprintf "MOSH_ARGS=<%%s>\\n" "$*"\n' > "$fake_bin/mosh"
chmod +x "$fake_bin/ssh" "$fake_bin/mosh"
zsh_wrapper_output="$(PATH="$fake_bin:$PATH" DANTERM=1 zsh -f -c '
    source "$1/danterm.zsh"
    ssh -o SendEnv=EXISTING "host name"
    mosh --server="mosh server" example
' _ "$integration_dir")"
bash_wrapper_output="$(PATH="$fake_bin:$PATH" DANTERM=1 bash --noprofile --norc -c '
    source "$1/danterm.bash"
    ssh -o SendEnv=EXISTING "host name"
    mosh --server="mosh server" example
' _ "$integration_dir")"
fish_wrapper_output="$(PATH="$fake_bin:$PATH" env DANTERM=1 fish --no-config -c '
    source $argv[1]/danterm.fish
    ssh -o SendEnv=EXISTING "host name"
    mosh --server="mosh server" example
' "$integration_dir")"
for wrapper_output in "$zsh_wrapper_output" "$bash_wrapper_output" "$fish_wrapper_output"; do
    assert_contains "$wrapper_output" "$prefix""remote-start$terminator"
    assert_contains "$wrapper_output" "SSH_ARGS=<-o SendEnv=LC_DANTERM -o SendEnv=EXISTING host name>"
    assert_contains "$wrapper_output" "MOSH_ARGS=<--server=mosh server example>"
done

remote_host="$(zsh -f -c 'printf %s "$HOST"')"
remote_output="$(PATH="$fake_bin:$PATH" env -u DANTERM LC_DANTERM=1 USER='user name' zsh -f -c '
    source "$1/danterm.zsh"
    [[ ${LC_DANTERM:-} == 1 ]] || exit 31
    _danterm_preexec true
    _danterm_precmd
    ssh nested
' _ "$integration_dir")"
outer_user="$(printf '%s' 'user name' | base64 | tr -d '\n')"
outer_host="$(printf '%s' "$remote_host" | base64 | tr -d '\n')"
outer_event="$prefix""remote-host;$outer_user;$outer_host$terminator"
assert_contains "$remote_output" "$prefix""command-end$terminator$outer_event$prefix""remote-start$terminator"
assert_not_contains "$remote_output" "$(printf '\033]7;')"
case "$remote_output" in
    *"$outer_event"*"SSH_ARGS=<"*"$outer_event") ;;
    *) fail "nested ssh did not restore outer host" ;;
esac

for remote_shell in bash fish; do
    if test "$remote_shell" = bash; then
        remote_case="$(PATH="$fake_bin:$PATH" env -u DANTERM LC_DANTERM=1 bash --noprofile --norc -c '
            source "$1/danterm.bash"
            [[ ${LC_DANTERM:-} == 1 ]] || exit 31
            _danterm_preexec true
            _danterm_precmd
            ssh nested
        ' _ "$integration_dir")"
    else
        remote_case="$(PATH="$fake_bin:$PATH" env -u DANTERM LC_DANTERM=1 fish --no-config -c '
            source $argv[1]/danterm.fish
            test "$LC_DANTERM" = 1; or exit 31
            emit fish_preexec true
            emit fish_postexec 0
            emit fish_prompt
            ssh nested
        ' "$integration_dir")"
    fi
    case "$remote_case" in
        *"remote-host;"*"remote-start"*"SSH_ARGS=<"*"remote-host;"*) ;;
        *) fail "$remote_shell nested ssh did not restore outer host" ;;
    esac
    case "$remote_case" in
        *"command-end"*"remote-host;"*) ;;
        *) fail "$remote_shell prompt did not restore its remote host" ;;
    esac
    assert_not_contains "$remote_case" "$(printf '\033]7;')"
done

echo "shell-integration tests passed"
