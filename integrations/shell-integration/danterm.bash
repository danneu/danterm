# Sourceable DanTerm integration for Bash command, cwd, SSH, and mosh metadata.

unset DANTERM_RESTORE_COMMAND

if [[ -n ${DANTERM_RESTORE_SCROLLBACK_FILE:-} ]]; then
    _danterm_scrollback_file=$DANTERM_RESTORE_SCROLLBACK_FILE
    unset DANTERM_RESTORE_SCROLLBACK_FILE
    if [[ -r $_danterm_scrollback_file ]]; then
        /bin/cat -- "$_danterm_scrollback_file" 2>/dev/null || true
        /bin/rm -f -- "$_danterm_scrollback_file" >/dev/null 2>&1 || true
    fi
    unset _danterm_scrollback_file
fi

[[ -z ${_DANTERM_SHELL_INTEGRATION_LOADED:-} ]] || return 0
readonly _DANTERM_SHELL_INTEGRATION_LOADED=1

_danterm_is_remote=''
[[ -z ${DANTERM:-} && -n ${LC_DANTERM:-} ]] && _danterm_is_remote=1
readonly _danterm_is_remote
readonly _danterm_enabled="${DANTERM:-${LC_DANTERM:-}}"

danterm_base64() { printf '%s' "$1" | base64 | tr -d '\n'; }
danterm_emit() {
    [[ -n $_danterm_enabled ]] || return 0
    printf '\033]1337;DanTermShell=1;%s\033\\' "$1"
}
danterm_emit_command_start() { danterm_emit "command-start;$(danterm_base64 "$1")"; }
danterm_emit_command_end() { danterm_emit command-end; }
danterm_emit_remote_start() { danterm_emit remote-start; }
danterm_emit_remote_host() {
    danterm_emit "remote-host;$(danterm_base64 "$1");$(danterm_base64 "$2")"
}
danterm_emit_cwd() {
    [[ -n $_danterm_enabled ]] || return 0
    [[ -z $_danterm_is_remote ]] || return 0
    printf '\033]7;file://%s%s\033\\' "${HOSTNAME:-localhost}" "$PWD"
}

__danterm_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$__danterm_dir/vendor/bash-preexec.sh"
unset __danterm_dir
_danterm_preexec() {
    _danterm_command_active=1
    danterm_emit_command_start "$1"
}
_danterm_precmd() {
    if [[ -n ${_danterm_command_active:-} ]]; then
        danterm_emit_command_end
        unset _danterm_command_active
    fi
    if [[ -n ${_danterm_remote_user:-} ]]; then
        danterm_emit_remote_host "$_danterm_remote_user" "$_danterm_remote_host"
    else
        danterm_emit_cwd
    fi
}
preexec_functions+=( _danterm_preexec )
precmd_functions+=( _danterm_precmd )

danterm_ssh() {
    danterm_emit_remote_start
    LC_DANTERM=1 command ssh -o SendEnv=LC_DANTERM "$@"
    if [[ -n ${_danterm_remote_user:-} ]]; then
        danterm_emit_remote_host "$_danterm_remote_user" "$_danterm_remote_host"
    fi
}
danterm_mosh() {
    danterm_emit_remote_start
    LC_DANTERM=1 command mosh "$@"
}
ssh() { danterm_ssh "$@"; }
mosh() { danterm_mosh "$@"; }

if [[ -n $_danterm_enabled && -n $_danterm_is_remote ]]; then
    _danterm_remote_user=${USER:-unknown}
    _danterm_remote_host=${HOSTNAME:-unknown}
    danterm_emit_remote_host "$_danterm_remote_user" "$_danterm_remote_host"
fi
