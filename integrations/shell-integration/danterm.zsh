# Sourceable DanTerm integration for zsh command, cwd, SSH, and mosh metadata.

if [[ -n ${DANTERM_RESTORE_COMMAND+x} ]]; then
    typeset -g _danterm_restore_command=$DANTERM_RESTORE_COMMAND
    unset DANTERM_RESTORE_COMMAND
fi

if [[ -n ${DANTERM_RESTORE_SCROLLBACK_FILE:-} ]]; then
    typeset _danterm_scrollback_file=$DANTERM_RESTORE_SCROLLBACK_FILE
    unset DANTERM_RESTORE_SCROLLBACK_FILE
    # `command` (not an absolute path) so restore also works on a host with no
    # /bin/cat or /bin/rm -- a NixOS or Nix-sandbox host, which is exactly where
    # the remote LC_DANTERM route lands. Absolute paths previously guarded
    # against a PATH hijack, but `command` already bypasses any function or
    # alias, and an attacker who can prepend to the PATH of the shell sourcing
    # this file already runs arbitrary code in it the moment any command does.
    if [[ -r $_danterm_scrollback_file ]]; then
        command cat -- "$_danterm_scrollback_file" 2>/dev/null || true
        command rm -f -- "$_danterm_scrollback_file" >/dev/null 2>&1 || true
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

# The OSC String Terminator, named once rather than spelled inline in each
# format. A lone backslash at the end of a printf format is passed through only
# incidentally; carrying the two bytes in a variable sidesteps format
# interpretation entirely. Same ANSI-C-quoting idiom as the `_danterm_p_*`
# prompt marks below, and matches danterm.bash.
typeset -gr _danterm_st=$'\033\\'

danterm_base64() { printf '%s' "$1" | base64 | tr -d '\n' }
danterm_emit() {
    [[ -n $_danterm_enabled ]] || return 0
    printf '\033]1337;DanTermShell=1;%s%s' "$1" "$_danterm_st"
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
    printf '\033]7;file://%s%s%s' "${HOST:-localhost}" "$PWD" "$_danterm_st"
}

danterm_emit_osc133() {
    [[ -n $_danterm_enabled ]] || return 0
    printf '\033]133;%s\a' "$1"
}

# --- OSC 133 prompt marks ---------------------------------------------------
#
# Row stamps that tell DanTerm's parser which rows belong to the prompt, plus
# the `redraw` promise that tells it how much of the prompt block it may blank
# before reflowing on a resize. zsh re-emits PS1 in full on every redisplay,
# SIGWINCH included, so the marks live *inside* PS1 -- that is what keeps the
# stamp and the declaration alive across a repaint, which printing them from
# precmd would not. `%{...%}` keeps them out of zsh's prompt width accounting.
# `redraw=1` is restated every prompt rather than once at load because the mode
# is per-pane terminal state that a nested shell can overwrite and that outlives
# that shell. See docs/research/24-osc-133-dialect (D0, D1).
typeset -g _danterm_p_open=$'%{\e]133;A;redraw=1\a%}'
typeset -g _danterm_p_cont=$'%{\e]133;A;k=s\a%}'
typeset -g _danterm_p_close=$'%{\e]133;B\a%}'

typeset -g _danterm_ps1_pristine='' _danterm_ps1_marked=''
typeset -g _danterm_ps2_pristine='' _danterm_ps2_marked=''

_danterm_mark_prompt() {
    [[ -n $_danterm_enabled ]] || return 0
    local nl=$'\n'

    # Rebuild from a pristine copy, re-capturing it whenever a third party has
    # changed the prompt out from under us. Wrapping "whatever PS1 is now"
    # instead composes the wrap with its own previous output and grows two marks
    # per prompt cycle without bound (F14).
    [[ -n $_danterm_ps1_marked && $PS1 == $_danterm_ps1_marked ]] || _danterm_ps1_pristine=$PS1
    local body=${_danterm_ps1_pristine//$nl/$nl$_danterm_p_cont}
    # A newline at the very start is already covered by the opening `A`'s fresh
    # line; stamping it as well would classify one row twice.
    [[ $_danterm_ps1_pristine == $nl* ]] && body=${body/#$nl$_danterm_p_cont/$nl}
    PS1=$_danterm_p_open$body$_danterm_p_close
    _danterm_ps1_marked=$PS1

    [[ -n $_danterm_ps2_marked && $PS2 == $_danterm_ps2_marked ]] || _danterm_ps2_pristine=$PS2
    PS2=$_danterm_p_cont${_danterm_ps2_pristine//$nl/$nl$_danterm_p_cont}$_danterm_p_close
    _danterm_ps2_marked=$PS2
}

typeset -g _danterm_zle_heal_installed=''

# Deferred to the first precmd rather than done at source time so that a widget
# defined later in ~/.zshrc is already registered and can be chained instead of
# clobbered. The first precmd still runs before the first zle-line-init, so the
# heal below is in place in time to fix the session's first prompt.
_danterm_install_zle_heal() {
    [[ -z $_danterm_zle_heal_installed ]] || return 0
    _danterm_zle_heal_installed=1
    if [[ ${widgets[zle-line-init]:-} == user:* ]]; then
        zle -A zle-line-init _danterm_zle_line_init_orig
    fi
    zle -N zle-line-init _danterm_zle_line_init
}

_danterm_zle_line_init() {
    # Heals the one prompt the precmd re-tail below cannot reach. `zleread`
    # expands the prompt before line-init runs
    # (references/zsh/Src/Zle/zle_main.c#zleread), so a wrap here only reaches
    # the screen if it also resets. Conditional on PS1 being unmarked: the
    # unconditional form paints every prompt twice for the life of the session.
    if [[ $PS1 != *$'\e]133;A'* ]]; then
        _danterm_mark_prompt
        zle reset-prompt
    fi
    (( ${+widgets[_danterm_zle_line_init_orig]} )) && zle _danterm_zle_line_init_orig
    return 0
}

_danterm_prompt_precmd() {
    [[ -n $_danterm_enabled ]] || return 0
    # Re-append ourselves to the tail of precmd_functions so a framework hook
    # registered after ours cannot leave us wrapping a PS1 it is about to
    # overwrite -- which is silent when it happens: no marks, no diagnostic.
    # zsh snapshots the hook array before iterating it
    # (references/zsh/Src/utils.c#callhookfunc), so this takes effect from the
    # next prompt and never the current one. That is exactly the prompt the
    # zle-line-init heal covers.
    precmd_functions=("${(@)precmd_functions:#_danterm_prompt_precmd}" _danterm_prompt_precmd)
    _danterm_install_zle_heal
    _danterm_mark_prompt
}

autoload -Uz add-zsh-hook
_danterm_preexec() {
    typeset -g _danterm_command_active=1
    danterm_emit_command_start "$1"
    # Emitted after the private envelope event so the mark sits adjacent to the
    # command's own output. `C` is what stops a resize mid-command from blanking
    # the prompt block underneath a running program.
    danterm_emit_osc133 C
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
add-zsh-hook precmd _danterm_prompt_precmd

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
