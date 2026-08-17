# Sourceable DanTerm integration for fish command, cwd, SSH, and mosh metadata.

if set -q DANTERM_RESTORE_COMMAND
    set -g _danterm_restore_command "$DANTERM_RESTORE_COMMAND"
    set -e DANTERM_RESTORE_COMMAND
end

if set -q DANTERM_RESTORE_SCROLLBACK_FILE
    set -l _danterm_scrollback_file "$DANTERM_RESTORE_SCROLLBACK_FILE"
    set -e DANTERM_RESTORE_SCROLLBACK_FILE
    # `command` (not an absolute path) so restore also works on a host with no
    # /bin/cat or /bin/rm -- a NixOS or Nix-sandbox host, which is exactly where
    # the remote LC_DANTERM route lands. Absolute paths previously guarded
    # against a PATH hijack, but `command` already bypasses any function or
    # alias, and an attacker who can prepend to the PATH of the shell sourcing
    # this file already runs arbitrary code in it the moment any command does.
    if test -r "$_danterm_scrollback_file"
        command cat -- "$_danterm_scrollback_file" 2>/dev/null; or true
        command rm -f -- "$_danterm_scrollback_file" >/dev/null 2>&1; or true
    end
end

set -q _DANTERM_SHELL_INTEGRATION_LOADED; and return 0
set -g _DANTERM_SHELL_INTEGRATION_LOADED 1

set -g _danterm_is_remote 0
not set -q DANTERM; and set -q LC_DANTERM; and test -n "$LC_DANTERM"; and set _danterm_is_remote 1
if set -q DANTERM; and test -n "$DANTERM"
    set -g _danterm_enabled "$DANTERM"
else if set -q LC_DANTERM; and test -n "$LC_DANTERM"
    set -g _danterm_enabled "$LC_DANTERM"
else
    set -g _danterm_enabled ''
end
set -g _danterm_st (printf '\e\\')

# `base64` wraps its output at 76 columns, so anything over 57 bytes arrives as
# several lines and the payload has to be rejoined. `string join` is what does
# that: inside single quotes fish reads `\n` as the two characters backslash and
# n, so the `string replace -a '\n' ''` this used to call matched nothing and
# left real newlines in the OSC payload -- which cut every reported command at
# 57 bytes.
function danterm_base64
    printf %s "$argv[1]" | base64 | string join ''
end
function danterm_emit
    test -n "$_danterm_enabled"; or return 0
    if set -q TMUX; and test -n "$TMUX"
        printf '\ePtmux;\e\e]1337;DanTermShell=3;%s\e%s%s' "$argv[1]" "$_danterm_st" "$_danterm_st"
    else
        printf '\e]1337;DanTermShell=3;%s%s' "$argv[1]" "$_danterm_st"
    end
end
function danterm_emit_integration_ready; danterm_emit integration-ready; end
function danterm_emit_command_start; danterm_emit "command-start;"(danterm_base64 "$argv[1]"); end
function danterm_emit_command_end; danterm_emit "command-end;$argv[1]"; end
function danterm_emit_connection_local; danterm_emit "connection;local"; end
function danterm_emit_connection_remote; danterm_emit "connection;remote"; end
function danterm_emit_connection_remote_identity
    danterm_emit "connection;remote;"(danterm_base64 "$argv[1]")";"(danterm_base64 "$argv[2]")
end
function danterm_emit_cwd
    test -n "$_danterm_enabled"; or return 0
    test $_danterm_is_remote = 0; or return 0
    printf '\e]7;file://%s%s\e\\' (hostname) "$PWD"
end

# The whole of DanTerm's OSC 133 contribution for fish. fish already emits
# A/B/C/D itself, so we add only the `redraw` declaration -- the promise that
# tells DanTerm's parser how much of the prompt block it may blank before a
# reflow. `1` means "I repaint the whole prompt", which is what fish does on
# SIGWINCH. Re-declared on every prompt, not once at load: the mode is
# per-pane terminal state that a nested shell can overwrite and that survives
# that shell's exit. See `research/24/D0` and `research/24/D3`.
function danterm_emit_prompt_redraw
    test -n "$_danterm_enabled"; or return 0
    printf '\e]133;A;redraw=1\a'
end

function _danterm_preexec --on-event fish_preexec
    danterm_emit_command_start "$argv[1]"
    set -g _danterm_command_active 1
end
function _danterm_postexec --on-event fish_postexec
    set -l _danterm_exit_status $status
    if set -q _danterm_command_active
        danterm_emit_command_end "$_danterm_exit_status"
        set -e _danterm_command_active
    end
end
function _danterm_prompt --on-event fish_prompt
    danterm_emit_prompt_redraw
    if set -q _danterm_remote_user
        danterm_emit_connection_remote_identity "$_danterm_remote_user" "$_danterm_remote_host"
    else
        danterm_emit_connection_local
        danterm_emit_cwd
    end
    if set -q _danterm_restore_command
        commandline --replace -- "$_danterm_restore_command"
        commandline --cursor (string length -- "$_danterm_restore_command")
        set -e _danterm_restore_command
    end
end

function danterm_ssh
    danterm_emit_connection_remote
    env LC_DANTERM=1 ssh -o SendEnv=LC_DANTERM $argv
end
function danterm_mosh
    danterm_emit_connection_remote
    env LC_DANTERM=1 mosh $argv
end
function ssh; danterm_ssh $argv; end
function mosh; danterm_mosh $argv; end

danterm_emit_integration_ready
if test -n "$_danterm_enabled"; and test $_danterm_is_remote = 1
    set -g _danterm_remote_user (whoami)
    set -g _danterm_remote_host (hostname)
    danterm_emit_connection_remote_identity "$_danterm_remote_user" "$_danterm_remote_host"
end
