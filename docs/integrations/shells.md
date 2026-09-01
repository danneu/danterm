# Shells

Shell integration lets DanTerm track the working directory, the running
command, and the remote identity of every pane. Without it a pane still works;
it just cannot label itself, inherit a cwd on split, or restore a command after
a crash.

Home Manager users get it from one option:

```nix
programs.danterm.shellIntegration.enable = true;
```

Everyone else adds the matching line to their shell config:

```sh
# ~/.zshrc
if [[ -n ${DANTERM_SHELL_INTEGRATION_DIR:-} ]]; then
  source "$DANTERM_SHELL_INTEGRATION_DIR/danterm.zsh"
fi

# ~/.bashrc
if [[ -n ${DANTERM_SHELL_INTEGRATION_DIR:-} ]]; then
  source "$DANTERM_SHELL_INTEGRATION_DIR/danterm.bash"
fi

# ~/.config/fish/config.fish
if set -q DANTERM_SHELL_INTEGRATION_DIR; and test -n "$DANTERM_SHELL_INTEGRATION_DIR"
  source "$DANTERM_SHELL_INTEGRATION_DIR/danterm.fish"
end
```

The guard matters. `DANTERM_SHELL_INTEGRATION_DIR` is set only by DanTerm, so
the same config file stays correct under every other terminal.

Bash needs one extra piece, which DanTerm ships: `bash-preexec`, vendored under
`integrations/shell-integration/vendor`. The `danterm.bash` script loads it.

For a shell on a remote host, see [ssh.md](ssh.md).

The sequences the integration emits, and what DanTerm does with each, are the
`shell-event` family in the
[terminal capability contract](../terminal-capabilities.md).
