# Tailnet remote IPC

Configure the listener with three config keys:

| Key                       | Meaning                                                                                                                  |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| `tailnet.listen`          | Tailnet IPv4 address and base TCP port, for example `"100.99.4.1:24863"`. Each instance adds its own offset to the port. |
| `tailnet.admittedNodeIds` | Stable Tailscale node ids allowed to use remote IPC. An empty list keeps the listener closed.                            |
| `tailnet.enable`          | Set to `false` to park an intact section: the settings stay on disk and the listener stays closed. Absent means `true`.  |

The tailnet listener is closed by default and reads its configuration only at
launch. It opens only on an address assigned to this Mac in 100.64.0.0/10, and
only when the admitted-node list is non-empty and the private audit log is
writable. A bad address, a port collision, or an unavailable audit sink leaves
local IPC and the app running normally, and the listener keeps retrying the same
endpoint until it binds -- so a Mac that starts DanTerm before Tailscale is up
comes online on its own.

The configured port is a base. Every instance on one Mac adds a fixed offset for
its own identity, so no two of them race for one port: production takes the base
port, and development slot N takes the base port plus 1 + N. Development slots 1
through 8 belong to the throwaway apps agents launch, and each reads a config
file of its own, so they stay closed unless one is launched with
`just launch-slot --tailnet`, which copies the endpoint into that slot's file --
on top of whatever `--seed-config` put there, if the launch named a seed. A
`--tailnet` launch against a section parked with `enable: false` is refused by
name before anything spawns, rather than starting a slot whose listener never
binds; a config with no tailnet section at all still launches, with nothing to
copy.

Ask a running instance which endpoint it derived, and whether it is bound:

```sh
danterm tailnet status
```

Connect with the shipped CLI from an admitted tailnet peer:

```sh
danterm --tcp 100.99.4.1:24863 ls
```

The TCP target is always explicit. It has no environment-variable form. The
same handshake, refusal messages, and commands used by the local control socket
run over this connection. The server refuses remote `quit` requests.
