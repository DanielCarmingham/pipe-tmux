# pipe-tmux Design

Bridge a tmux pane to an IRC channel. All pane output streams to IRC; IRC messages inject keystrokes back into the pane.

## Architecture

Single bash script using `ii` (suckless filesystem-based IRC client). Two loops:

```
tmux pipe-pane → debounce buffer → ii in FIFO → IRC channel
IRC channel → ii out file → tail -f → parse → tmux send-keys
```

## IRC Connection

`ii` runs in background, creates filesystem interface:
- `server/channel/in` — FIFO, write here to send messages
- `server/channel/out` — regular file, tail to read messages

## Tmux → IRC (output streaming)

- `tmux pipe-pane -t <target>` streams raw pane output to the script
- Debounce buffer accumulates output, flushes to IRC after a configurable quiet period (default 2s)
- Lines split at ~450 chars to fit IRC protocol limits

## IRC → Tmux (command injection)

- `tail -f` on channel's `out` file, parse incoming messages
- Plain messages: `tmux send-keys -l "text"` then `tmux send-keys Enter`
- `!` prefix: strip `!`, pass remainder directly to `tmux send-keys` (e.g. `!C-a d` → `tmux send-keys C-a d`)

## Startup Commands

- `-e "command"` flag (repeatable) runs tmux commands on connect
- Default: `set status off` (disable status bar on target pane)
- `-E` flag skips defaults
- `startup=` lines in config file are additive

## Config File

- Default: `~/.pipe-tmux.conf` (loaded automatically if present)
- Override: `-f /path/to/config`
- CLI args override config file; config file overrides defaults
- Format: `KEY=VALUE`, `#` comments

```
server=irc.server.net
port=6667
channel=#channel
target=pipetest:0.0
nick=pipe-tmux
debounce=2
startup=set status off
startup=send-keys "echo hello"
```

Load order: defaults → config file → CLI args.

## CLI Flags

| Flag | Description | Default |
|------|-------------|---------|
| `-s` | IRC server hostname | (required) |
| `-c` | IRC channel | (required) |
| `-t` | tmux target pane | (required) |
| `-n` | IRC nickname | `pipe-tmux` |
| `-p` | IRC port | `6667` |
| `-d` | Debounce interval (seconds) | `2` |
| `-e` | Startup tmux command (repeatable) | `set status off` |
| `-E` | Skip default startup commands | — |
| `-i` | ii IRC directory | `/tmp/pipe-tmux.$$` |
| `-f` | Config file path | `~/.pipe-tmux.conf` |

## Auth

None. Trusted network assumed. All IRC users in the channel can send commands.

## Cleanup

On exit (trap SIGINT/SIGTERM): kill `ii`, stop `pipe-pane`, remove temp directory.
