# Sourceable DanTerm integration for zsh command, cwd, SSH, and mosh metadata.

if [[ -n ${DANTERM_RESTORE_COMMAND+x} ]]; then
    typeset -g _danterm_restore_command=$DANTERM_RESTORE_COMMAND
    unset DANTERM_RESTORE_COMMAND
fi

if [[ -n ${DANTERM_RESTORE_SCROLLBACK_FILE:-} ]]; then
    typeset _danterm_scrollback_file=$DANTERM_RESTORE_SCROLLBACK_FILE
    unset DANTERM_RESTORE_SCROLLBACK_FILE
    if [[ -r $_danterm_scrollback_file ]]; then
        /bin/cat -- "$_danterm_scrollback_file" 2>/dev/null || true
        /bin/rm -f -- "$_danterm_scrollback_file" >/dev/null 2>&1 || true
    fi
    unset _danterm_scrollback_file
fi

if [[ -n ${_DANTERM_SHELL_INTEGRATION_LOADED:-} ]]; then
    return 0
fi
typeset -gr _DANTERM_SHELL_INTEGRATION_LOADED=1

typeset -g _danterm_is_remote=''
[[ -z ${DANTERM:-} && -n ${LC_DANTERM:-} ]] && _danterm_is_remote=1
typeset -gr _danterm_is_remote
typeset -gr _danterm_enabled=${DANTERM:-${LC_DANTERM:-}}

danterm_base64() { printf '%s' "$1" | base64 | tr -d '\n' }
danterm_emit() {
    [[ -n $_danterm_enabled ]] || return 0
    printf '\033]1337;DanTermShell=1;%s\033\\' "$1"
}
danterm_emit_command_start() { danterm_emit "command-start;$(danterm_base64 "$1")" }
danterm_emit_command_end() { danterm_emit command-end }
danterm_emit_remote_start() { danterm_emit remote-start }
danterm_emit_remote_host() {
    danterm_emit "remote-host;$(danterm_base64 "$1");$(danterm_base64 "$2")"
}
danterm_emit_cwd() {
    [[ -n $_danterm_enabled ]] || return 0
    [[ -z $_danterm_is_remote ]] || return 0
    printf '\033]7;file://%s%s\033\\' "${HOST:-localhost}" "$PWD"
}

autoload -Uz add-zsh-hook
_danterm_preexec() {
    typeset -g _danterm_command_active=1
    danterm_emit_command_start "$1"
}
_danterm_precmd() {
    if [[ -n ${_danterm_command_active:-} ]]; then
        danterm_emit_command_end
        unset _danterm_command_active
    fi
    if [[ -n ${_danterm_remote_identity:-} ]]; then
        danterm_emit_remote_host "${_danterm_remote_identity%%:*}" "${_danterm_remote_identity#*:}"
    else
        danterm_emit_cwd
    fi
    if [[ -n ${_danterm_restore_command+x} ]]; then
        print -z -- "$_danterm_restore_command"
        unset _danterm_restore_command
    fi
}
add-zsh-hook preexec _danterm_preexec
add-zsh-hook precmd _danterm_precmd

danterm_ssh() {
    danterm_emit_remote_start
    LC_DANTERM=1 command ssh -o SendEnv=LC_DANTERM "$@"
    if [[ -n ${_danterm_remote_identity:-} ]]; then
        danterm_emit_remote_host "${_danterm_remote_identity%%:*}" "${_danterm_remote_identity#*:}"
    fi
}
danterm_mosh() {
    danterm_emit_remote_start
    LC_DANTERM=1 command mosh "$@"
}
ssh() { danterm_ssh "$@" }
mosh() { danterm_mosh "$@" }

if [[ -n $_danterm_enabled && -n $_danterm_is_remote ]]; then
    typeset -g _danterm_remote_identity="${USER:-unknown}:${HOST:-${HOSTNAME:-unknown}}"
    danterm_emit_remote_host "${USER:-unknown}" "${HOST:-${HOSTNAME:-unknown}}"
fi
