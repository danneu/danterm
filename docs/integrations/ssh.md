# SSH

DanTerm gives a remote pane its own theme (`theme.remote`, default
`Purplepeter`) so a remote pane never looks like a local one, and labels the
pane with the user and host it is talking to.

Neither is guessed from the screen. Both come from the shell integration, in
two halves.

## Local half: the pane learns it went remote

The local integration wraps `ssh` and `mosh`. The wrapper announces the pane is
going remote, then sets `LC_DANTERM=1` and asks SSH to forward it:

```sh
danterm_ssh() {
    danterm_emit_connection_remote
    LC_DANTERM=1 command ssh -o SendEnv=LC_DANTERM "$@"
}
```

So the remote theme needs nothing beyond [shell integration](shells.md) on your
Mac. Invoking `command ssh` or a different SSH client bypasses the wrapper, and
the pane stays local-looking.

## Remote half: the pane learns who it is talking to

The user and host label needs the integration running on the far side. Copy it
to the host and source it from the remote shell config:

```sh
scp -r /Applications/DanTerm.app/Contents/Resources/shell-integration \
  user@host:~/.danterm-shell-integration

source ~/.danterm-shell-integration/danterm.zsh
```

Use `danterm.bash` or `danterm.fish` for those shells.

The remote integration only speaks up when it sees `LC_DANTERM`, and `sshd`
drops that unless it is told not to:

```sshconfig
# /etc/ssh/sshd_config
AcceptEnv LC_*
```

Refresh the copied directory after upgrading DanTerm. DanTerm ignores identity
reports from an older copy rather than trusting a stale dialect.

If you run tmux on the far side, read [tmux.md](tmux.md) as well: a multiplexer
sits between the remote shell and DanTerm and changes what gets through.
