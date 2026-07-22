# Sourceable DanTerm integration for fish command, cwd, SSH, and mosh metadata.

if set -q DANTERM_RESTORE_COMMAND
    set -g _danterm_restore_command "$DANTERM_RESTORE_COMMAND"
    set -e DANTERM_RESTORE_COMMAND
end

if set -q DANTERM_RESTORE_SCROLLBACK_FILE
    set -l _danterm_scrollback_file "$DANTERM_RESTORE_SCROLLBACK_FILE"
    set -e DANTERM_RESTORE_SCROLLBACK_FILE
    if test -r "$_danterm_scrollback_file"
        /bin/cat -- "$_danterm_scrollback_file" 2>/dev/null; or true
        /bin/rm -f -- "$_danterm_scrollback_file" >/dev/null 2>&1; or true
    end
end

set -q _DANTERM_SHELL_INTEGRATION_LOADED; and return 0
set -g _DANTERM_SHELL_INTEGRATION_LOADED 1

set -g _danterm_is_remote 0
not set -q DANTERM_TOKEN; and set -q LC_DANTERM_TOKEN; and test -n "$LC_DANTERM_TOKEN"; and set _danterm_is_remote 1
if set -q DANTERM_TOKEN; and test -n "$DANTERM_TOKEN"
    set -g _danterm_token "$DANTERM_TOKEN"
else if set -q LC_DANTERM_TOKEN; and test -n "$LC_DANTERM_TOKEN"
    set -g _danterm_token "$LC_DANTERM_TOKEN"
else
    set -g _danterm_token ''
end
set -e DANTERM_TOKEN LC_DANTERM_TOKEN

function danterm_base64
    printf %s "$argv[1]" | base64 | string collect | string replace -a '\n' ''
end
function danterm_emit
    test -n "$_danterm_token"; or return 0
    printf '\e]1337;DanTermShell=1;%s;%s\e\\' "$_danterm_token" "$argv[1]"
end
function danterm_emit_command_start; danterm_emit "command-start;"(danterm_base64 "$argv[1]"); end
function danterm_emit_command_end; danterm_emit command-end; end
function danterm_emit_remote_start; danterm_emit remote-start; end
function danterm_emit_remote_host
    danterm_emit "remote-host;"(danterm_base64 "$argv[1]")";"(danterm_base64 "$argv[2]")
end
function danterm_emit_cwd
    test $_danterm_is_remote = 0; or return 0
    printf '\e]7;file://%s%s\e\\' (hostname) "$PWD"
end

function _danterm_preexec --on-event fish_preexec
    danterm_emit_command_start "$argv[1]"
    set -g _danterm_command_active 1
end
function _danterm_postexec --on-event fish_postexec
    if set -q _danterm_command_active
        danterm_emit_command_end
        set -e _danterm_command_active
    end
end
function _danterm_prompt --on-event fish_prompt
    if set -q _danterm_remote_user
        danterm_emit_remote_host "$_danterm_remote_user" "$_danterm_remote_host"
    else
        danterm_emit_cwd
    end
    if set -q _danterm_restore_command
        commandline --replace -- "$_danterm_restore_command"
        commandline --cursor (string length -- "$_danterm_restore_command")
        set -e _danterm_restore_command
    end
end

function danterm_ssh
    danterm_emit_remote_start
    env LC_DANTERM_TOKEN="$_danterm_token" ssh -o SendEnv=LC_DANTERM_TOKEN $argv
    if set -q _danterm_remote_user
        danterm_emit_remote_host "$_danterm_remote_user" "$_danterm_remote_host"
    end
end
function danterm_mosh
    danterm_emit_remote_start
    env LC_DANTERM_TOKEN="$_danterm_token" mosh $argv
end
function ssh; danterm_ssh $argv; end
function mosh; danterm_mosh $argv; end

if test -n "$_danterm_token"; and test $_danterm_is_remote = 1
    set -g _danterm_remote_user (whoami)
    set -g _danterm_remote_host (hostname)
    danterm_emit_remote_host "$_danterm_remote_user" "$_danterm_remote_host"
end
