# pipe-tmux

Bridge a tmux pane to an IRC channel. All pane output streams to IRC (debounced), and IRC messages are injected back into the pane as keystrokes.

Uses [ii](https://tools.suckless.org/ii/) (suckless IRC client) under the hood.

## Requirements

- `tmux`
- `ii` (suckless IRC client)
- `perl`

## Quick Start

```bash
# Copy and edit the config
cp example.pipe-tmux.conf ~/.pipe-tmux.conf
vim ~/.pipe-tmux.conf

# Run (loads ~/.pipe-tmux.conf automatically)
./pipe-tmux.sh
```

Or pass everything on the command line:

```bash
./pipe-tmux.sh -s irc.example.com -c '#mychannel' -t mysession:0.0
```

## Config File

By default, `~/.pipe-tmux.conf` is loaded if it exists. Use `-f` to specify a different file. CLI arguments override config values.

```ini
server=irc.example.com
port=6667
channel=#mychannel
target=mysession:0.0
nick=pipe-tmux
debounce=2
startup=set status off
```

| Key | Description | Default |
|-----|-------------|---------|
| `server` | IRC server hostname | *(required)* |
| `port` | IRC server port | `6667` |
| `channel` | IRC channel to join | *(required)* |
| `target` | tmux target pane (e.g. `session:window.pane`) | *(required)* |
| `nick` | IRC nickname | `pipe-tmux` |
| `debounce` | Seconds to wait for output to stabilize before sending | `2` |
| `startup` | tmux command to run on connect (repeatable) | `set status off` |

## CLI Options

```
-s HOST    IRC server hostname
-c CHAN    IRC channel
-t PANE   tmux target pane (e.g. session:0.0)
-n NICK   IRC nickname (default: pipe-tmux)
-p PORT   IRC port (default: 6667)
-d SECS   Debounce interval in seconds (default: 2)
-e CMD    Startup tmux command (repeatable)
-E        Skip default startup commands (set status off)
-i DIR    ii working directory (default: /tmp/pipe-tmux.PID)
-f FILE   Config file (default: ~/.pipe-tmux.conf)
-h        Show help
```

## Sending Commands from IRC

### Plain text

Type a message in the IRC channel and it will be sent to the tmux pane as literal keystrokes followed by Enter.

```
ls -la           →  types "ls -la" then presses Enter
echo hello       →  types "echo hello" then presses Enter
```

### Key sequences (`!` prefix)

Prefix with `!` to send tmux key names instead of literal text:

```
!C-c             →  sends Ctrl+C
!Up Up Up Enter  →  sends Up arrow 3 times then Enter
!C-a d           →  sends Ctrl+A then d (tmux detach with default prefix)
```

### Escape sequences (`!` prefix with `\x1b` or `\e`)

Use `\x1b` or `\e` in `!` messages to send raw escape sequences:

```
!\x1b[A          →  sends escape sequence for Up arrow
!\e[B            →  sends escape sequence for Down arrow
```

## How It Works

1. Starts `ii` to connect to IRC
2. Polls `tmux capture-pane` every 0.5s to detect new output
3. Debounces output changes, then sends new lines to IRC
4. Short lines are accumulated into single IRC messages (joined with ` | `, up to 450 chars)
5. ANSI color codes are converted to IRC color codes
6. Monitors the IRC channel for incoming messages and injects them into the tmux pane

## Stopping

Press `Ctrl+C` to stop the bridge. It will clean up all child processes and temp files.
