#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
integration_dir="$repo_root/integrations/shell-integration"

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
terminator="$(printf '\033\\')"

for asset in danterm.zsh danterm.bash danterm.fish vendor/bash-preexec.sh vendor/bash-preexec.LICENSE vendor/bash-preexec.PROVENANCE; do
    test -f "$integration_dir/$asset" || fail "missing $asset"
done

for shell in zsh bash fish; do
    restore_file="$(mktemp)"
    printf 'restored scrollback' > "$restore_file"
    restore_command='printf first
printf second'
    case "$shell" in
        zsh)
            restore_output="$(DANTERM_RESTORE_SCROLLBACK_FILE="$restore_file" DANTERM_RESTORE_COMMAND="$restore_command" /usr/bin/env zsh -f -c 'source "$1/danterm.zsh"; [[ -z ${DANTERM_RESTORE_COMMAND+x} ]] || exit 34; printf "|%s" "$_danterm_restore_command"' _ "$integration_dir")"
            ;;
        bash)
            restore_output="$(DANTERM_RESTORE_SCROLLBACK_FILE="$restore_file" DANTERM_RESTORE_COMMAND="$restore_command" /bin/bash --noprofile --norc -c 'source "$1/danterm.bash"; [[ -z ${DANTERM_RESTORE_COMMAND+x} ]] || exit 34; printf "|unset"' _ "$integration_dir")"
            ;;
        fish)
            restore_output="$(env DANTERM_RESTORE_SCROLLBACK_FILE="$restore_file" DANTERM_RESTORE_COMMAND="$restore_command" /usr/bin/env fish --no-config -c 'source $argv[1]/danterm.fish; set -q DANTERM_RESTORE_COMMAND; and exit 34; printf "|%s" "$_danterm_restore_command"' "$integration_dir")"
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
    SHELL_UNDER_TEST="$shell" INTEGRATION_DIR="$integration_dir" /usr/bin/expect <<'EXPECT' || fail "$shell did not seed restore command safely"
set timeout 10
set shell $env(SHELL_UNDER_TEST)
set integration $env(INTEGRATION_DIR)
set marker DANTERM_PREFILL_EXECUTED
set command "printf DANTERM_PREFILL_%s EXECUTED"
if {$shell eq "zsh"} {
    spawn env DANTERM_RESTORE_COMMAND=$command "PROMPT=DANTERM_PROMPT> " zsh -f
    expect "DANTERM_PROMPT> "
    send -- "source $integration/danterm.zsh\r"
} else {
    spawn env DANTERM_RESTORE_COMMAND=$command fish_greeting= fish --no-config
    expect -re {> $}
    send -- "function fish_prompt; printf 'DANTERM_PROMPT> '; end\r"
    expect "DANTERM_PROMPT> "
    send -- "source $integration/danterm.fish\r"
}
expect $command
set timeout 1
expect {
    $marker { exit 35 }
    timeout {}
}
set timeout 10
send -- "\r"
expect $marker
send -- "exit\r"
expect eof
EXPECT
done

zsh_output="$(DANTERM=1 /usr/bin/env zsh -f -c '
    source "$1/danterm.zsh"
    source "$1/danterm.zsh"
    [[ ${DANTERM:-} == 1 ]] || exit 31
    danterm_emit_command_start "$2"
    danterm_emit_command_end
    danterm_emit_remote_start
    danterm_emit_remote_host "user name" host.example
' _ "$integration_dir" "$command_text")"

bash_output="$(DANTERM=1 /bin/bash --noprofile --norc -c '
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

fish_output="$(env DANTERM=1 /usr/bin/env fish --no-config -c '
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
            silent_output="$(env -u DANTERM -u LC_DANTERM /usr/bin/env zsh -f -c 'source "$1/danterm.zsh"; danterm_emit_command_end; danterm_emit_cwd' _ "$integration_dir")"
            ;;
        bash)
            silent_output="$(env -u DANTERM -u LC_DANTERM /bin/bash --noprofile --norc -c 'source "$1/danterm.bash"; danterm_emit_command_end; danterm_emit_cwd' _ "$integration_dir")"
            ;;
        fish)
            silent_output="$(env -u DANTERM -u LC_DANTERM /usr/bin/env fish --no-config -c 'source $argv[1]/danterm.fish; danterm_emit_command_end; danterm_emit_cwd' "$integration_dir")"
            ;;
    esac
    test -z "$silent_output" || fail "$shell integration emitted without a DanTerm marker"
done

zsh_hooks="$(DANTERM=1 /usr/bin/env zsh -f -c '
    old_hook() { :; }
    precmd_functions=(old_hook)
    source "$1/danterm.zsh"
    [[ " ${precmd_functions[*]} " == *" old_hook "* ]] || exit 32
    _danterm_preexec "$2"
    _danterm_precmd
' _ "$integration_dir" "$command_text")"
bash_hooks="$(DANTERM=1 /bin/bash --noprofile --norc -c '
    source "$1/danterm.bash"
    _danterm_preexec "$2"
    _danterm_precmd
' _ "$integration_dir" "$command_text")"
fish_hooks="$(env DANTERM=1 /usr/bin/env fish --no-config -c '
    function old_handler --on-event fish_prompt; end
    source $argv[1]/danterm.fish
    functions -q old_handler; or exit 32
    emit fish_preexec $argv[2]
    emit fish_postexec 0
    emit fish_prompt
' "$integration_dir" "$command_text")"
for hook_output in "$zsh_hooks" "$bash_hooks" "$fish_hooks"; do
    assert_contains "$hook_output" "$prefix""command-start;$encoded_command$terminator$prefix""command-end$terminator"
    assert_contains "$hook_output" "$(printf '\033]7;file://')"
done

precedence_output="$(env DANTERM=1 LC_DANTERM=1 /usr/bin/env zsh -f -c '
    source "$1/danterm.zsh"
    danterm_emit_command_end
' _ "$integration_dir")"
test "$precedence_output" = "$prefix""command-end$terminator" || fail "local marker did not take precedence"

fake_bin="$(mktemp -d)"
trap 'rm -rf "$fake_bin"' EXIT
printf '#!/bin/sh\nprintf "SSH_ARGS=<%%s>\\n" "$*"\n' > "$fake_bin/ssh"
printf '#!/bin/sh\nprintf "MOSH_ARGS=<%%s>\\n" "$*"\n' > "$fake_bin/mosh"
chmod +x "$fake_bin/ssh" "$fake_bin/mosh"
zsh_wrapper_output="$(PATH="$fake_bin:$PATH" DANTERM=1 /usr/bin/env zsh -f -c '
    source "$1/danterm.zsh"
    ssh -o SendEnv=EXISTING "host name"
    mosh --server="mosh server" example
' _ "$integration_dir")"
bash_wrapper_output="$(PATH="$fake_bin:$PATH" DANTERM=1 /bin/bash --noprofile --norc -c '
    source "$1/danterm.bash"
    ssh -o SendEnv=EXISTING "host name"
    mosh --server="mosh server" example
' _ "$integration_dir")"
fish_wrapper_output="$(PATH="$fake_bin:$PATH" env DANTERM=1 /usr/bin/env fish --no-config -c '
    source $argv[1]/danterm.fish
    ssh -o SendEnv=EXISTING "host name"
    mosh --server="mosh server" example
' "$integration_dir")"
for wrapper_output in "$zsh_wrapper_output" "$bash_wrapper_output" "$fish_wrapper_output"; do
    assert_contains "$wrapper_output" "$prefix""remote-start$terminator"
    assert_contains "$wrapper_output" "SSH_ARGS=<-o SendEnv=LC_DANTERM -o SendEnv=EXISTING host name>"
    assert_contains "$wrapper_output" "MOSH_ARGS=<--server=mosh server example>"
done

remote_host="$(/usr/bin/env zsh -f -c 'printf %s "$HOST"')"
remote_output="$(PATH="$fake_bin:$PATH" env -u DANTERM LC_DANTERM=1 USER='user name' /usr/bin/env zsh -f -c '
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
        remote_case="$(PATH="$fake_bin:$PATH" env -u DANTERM LC_DANTERM=1 /bin/bash --noprofile --norc -c '
            source "$1/danterm.bash"
            [[ ${LC_DANTERM:-} == 1 ]] || exit 31
            _danterm_preexec true
            _danterm_precmd
            ssh nested
        ' _ "$integration_dir")"
    else
        remote_case="$(PATH="$fake_bin:$PATH" env -u DANTERM LC_DANTERM=1 /usr/bin/env fish --no-config -c '
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
