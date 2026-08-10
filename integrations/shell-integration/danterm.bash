# Sourceable DanTerm integration for Bash command, cwd, SSH, and mosh metadata.

unset DANTERM_RESTORE_COMMAND

if [[ -n ${DANTERM_RESTORE_SCROLLBACK_FILE:-} ]]; then
    _danterm_scrollback_file=$DANTERM_RESTORE_SCROLLBACK_FILE
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

[[ -z ${_DANTERM_SHELL_INTEGRATION_LOADED:-} ]] || return 0
readonly _DANTERM_SHELL_INTEGRATION_LOADED=1

_danterm_is_remote=''
[[ -z ${DANTERM:-} && -n ${LC_DANTERM:-} ]] && _danterm_is_remote=1
readonly _danterm_is_remote
readonly _danterm_enabled="${DANTERM:-${LC_DANTERM:-}}"

# The OSC String Terminator, named once rather than spelled inline in each
# format. A trailing `\\` inside a printf format is both the one construct in
# this file that reads as a botched quote escape and a lone backslash at the end
# of a format string, which printf only incidentally passes through; carrying the
# two bytes in a variable sidesteps format interpretation entirely. Same
# ANSI-C-quoting idiom as the `_danterm_esc`/`_danterm_bel` constants below.
readonly _danterm_st=$'\033\\'

danterm_base64() { printf '%s' "$1" | base64 | tr -d '\n'; }
danterm_emit() {
    [[ -n $_danterm_enabled ]] || return 0
    printf '\033]1337;DanTermShell=1;%s%s' "$1" "$_danterm_st"
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
    printf '\033]7;file://%s%s%s' "${HOSTNAME:-localhost}" "$PWD" "$_danterm_st"
}

danterm_emit_osc133() {
    [[ -n $_danterm_enabled ]] || return 0
    printf '\033]133;%s\007' "$1"
}

# --- OSC 133 prompt marks ---------------------------------------------------
#
# Bash differs from zsh in both halves of the dialect, and both differences are
# measured rather than inherited (`research/24/D0`, `research/24/D2`):
#
#   * `redraw=last`, not `redraw=1`. The mode is a promise about what the shell
#     will repaint after a resize, and DanTerm blanks exactly that much. readline
#     repaints only the *final* line of a multi-line prompt, so promising the
#     whole block would erase the upper lines permanently. Emitting nothing is
#     not the safe option either -- the parser's default is `full`, so an
#     unmarked Bash prompt loses its upper row outright.
#   * `P;k=i` inside PS1, not `A`. `A` performs a fresh line, and readline
#     redisplays mid-line (Ctrl-L, vi-mode switches). `P` stamps the row without
#     one. `A` is printed separately, once per prompt, from the hook below.
#
# The marks are wrapped in `\[...\]` so readline excludes them from its width
# calculation.
_danterm_esc=$'\033'
_danterm_bel=$'\007'
readonly _danterm_p_i="\\[${_danterm_esc}]133;P;k=i${_danterm_bel}\\]"
readonly _danterm_p_s="\\[${_danterm_esc}]133;P;k=s${_danterm_bel}\\]"
readonly _danterm_p_close="\\[${_danterm_esc}]133;B${_danterm_bel}\\]"
unset _danterm_esc _danterm_bel

_danterm_ps1_pristine=''
_danterm_ps1_marked=''
_danterm_ps2_pristine=''
_danterm_ps2_marked=''

_danterm_mark_prompt() {
    # Substitute the `\n` prompt *escape*, never a literal newline: a literal one
    # can appear inside a `$(...)` substitution in PS1, where injecting an escape
    # would break shell syntax. The pattern is quoted so `\n` is matched
    # literally instead of as an escaped `n`.
    local nlesc='\n'

    # Rebuild from a pristine copy, re-captured whenever a third party has
    # changed the prompt underneath us. Wrapping "whatever PS1 is now" instead
    # composes the wrap with its own previous output, once per prompt, forever.
    [[ -n $_danterm_ps1_marked && $PS1 == "$_danterm_ps1_marked" ]] || _danterm_ps1_pristine=$PS1
    PS1="${_danterm_p_i}${_danterm_ps1_pristine//"$nlesc"/$nlesc$_danterm_p_s}${_danterm_p_close}"
    _danterm_ps1_marked=$PS1

    [[ -n $_danterm_ps2_marked && $PS2 == "$_danterm_ps2_marked" ]] || _danterm_ps2_pristine=$PS2
    PS2="${_danterm_p_s}${_danterm_ps2_pristine//"$nlesc"/$nlesc$_danterm_p_s}${_danterm_p_close}"
    _danterm_ps2_marked=$PS2
}

# Re-append ourselves to the end of PROMPT_COMMAND on every run. Prompt
# frameworks rebuild PS1 from their own PROMPT_COMMAND entry -- Starship does it
# on *every* prompt -- so whoever runs last wins, and a source-time assignment
# loses in either source order.
_danterm_prompt_retail() {
    # PROMPT_COMMAND became array-capable in bash 5.1; macOS still ships 3.2,
    # where `${var@a}` is a runtime "bad substitution". The version test
    # short-circuits before that expansion is ever evaluated.
    if [[ ${BASH_VERSINFO[0]} -ge 5 ]] && [[ ${PROMPT_COMMAND@a} == *a* ]]; then
        local -a _danterm_keep=()
        local _danterm_entry _danterm_nl=$'\n'
        for _danterm_entry in "${PROMPT_COMMAND[@]}"; do
            # A single array element can hold several newline-separated commands:
            # bash-preexec folds whatever string PROMPT_COMMAND held at install
            # time into one element, which swallows our source-time registration.
            # Strip our own line out of such a composite rather than only matching
            # whole elements, or we stay embedded in it and run twice per prompt.
            _danterm_entry=${_danterm_entry//"$_danterm_nl"_danterm_prompt_command/}
            _danterm_entry=${_danterm_entry#_danterm_prompt_command"$_danterm_nl"}
            [[ $_danterm_entry == _danterm_prompt_command || -z $_danterm_entry ]] ||
                _danterm_keep+=("$_danterm_entry")
        done
        PROMPT_COMMAND=("${_danterm_keep[@]}" _danterm_prompt_command)
    else
        # The separator goes through a variable because `$'\n'` inside double
        # quotes is not ANSI-C quoting -- it would embed a literal `$'\n'`.
        local _danterm_nl=$'\n'
        # shellcheck disable=SC2128,SC2178 # string form: PROMPT_COMMAND is not an array here
        [[ $PROMPT_COMMAND == *_danterm_prompt_command ]] ||
            PROMPT_COMMAND="${PROMPT_COMMAND:+${PROMPT_COMMAND}${_danterm_nl}}_danterm_prompt_command"
    fi
}

_danterm_prompt_command() {
    [[ -n $_danterm_enabled ]] || return 0
    danterm_emit_osc133 'A;redraw=last'
    _danterm_mark_prompt
    _danterm_prompt_retail
}

__danterm_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$__danterm_dir/vendor/bash-preexec.sh"
unset __danterm_dir
_danterm_preexec() {
    _danterm_command_active=1
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
    if [[ -n ${_danterm_remote_user:-} ]]; then
        danterm_emit_remote_host "$_danterm_remote_user" "$_danterm_remote_host"
    else
        danterm_emit_cwd
    fi
}
preexec_functions+=( _danterm_preexec )
precmd_functions+=( _danterm_precmd )
# Deliberately NOT a precmd_functions entry: bash-preexec drives those from the
# *front* of PROMPT_COMMAND, and the prompt wrap has to run last. This registers
# the tail position it will then keep re-claiming on every prompt.
_danterm_prompt_retail

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
