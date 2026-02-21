# pipe-tmux Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Create a bash script that bridges a tmux pane to an IRC channel using ii, streaming all pane output to IRC and injecting IRC messages as keystrokes back into the pane.

**Architecture:** Single bash script (`pipe-tmux.sh`) using `ii` for IRC via filesystem interface. Two background loops: tmux→IRC (pipe-pane + debounce + flush) and IRC→tmux (tail + parse + send-keys). Config loaded from file then overridden by CLI args.

**Tech Stack:** Bash, ii (suckless IRC client), tmux, sed, tail

---

### Task 1: Script skeleton with config, args, and validation

**Files:**
- Create: `pipe-tmux.sh`

**Step 1: Create the script with all config/args/validation logic**

```bash
#!/bin/bash
set -euo pipefail

PROG="pipe-tmux"

# Defaults
SERVER=""
PORT="6667"
CHANNEL=""
TARGET=""
NICK="pipe-tmux"
DEBOUNCE="2"
IRCDIR="/tmp/$PROG.$$"
CONFFILE="$HOME/.$PROG.conf"
SKIP_DEFAULTS=false
declare -a STARTUP_CMDS=()
declare -a PIDS=()

usage() {
    cat <<EOF
Usage: $PROG -s server -c channel -t target [options]

Bridge a tmux pane to an IRC channel.

Options:
  -s HOST    IRC server hostname (required)
  -c CHAN    IRC channel (required)
  -t PANE   tmux target pane, e.g. session:0.0 (required)
  -n NICK   IRC nickname (default: pipe-tmux)
  -p PORT   IRC port (default: 6667)
  -d SECS   Debounce interval in seconds (default: 2)
  -e CMD    Startup tmux command (repeatable, run as 'tmux CMD')
  -E        Skip default startup commands (set status off)
  -i DIR    ii IRC directory (default: /tmp/$PROG.PID)
  -f FILE   Config file (default: ~/.$PROG.conf)
  -h        Show this help
EOF
    exit 0
}

die() { echo "$PROG: error: $*" >&2; exit 1; }
log() { echo "$PROG: $*"; }

load_config() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    log "loading config from $file"
    while IFS='=' read -r key value; do
        # Skip comments and blank lines
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$key" ]] && continue
        # Trim whitespace
        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        case "$key" in
            server)   SERVER="$value" ;;
            port)     PORT="$value" ;;
            channel)  CHANNEL="$value" ;;
            target)   TARGET="$value" ;;
            nick)     NICK="$value" ;;
            debounce) DEBOUNCE="$value" ;;
            startup)  STARTUP_CMDS+=("$value") ;;
            *)        log "unknown config key: $key" ;;
        esac
    done < "$file"
}

parse_args() {
    while getopts "s:c:t:n:p:d:e:Ei:f:h" opt; do
        case "$opt" in
            s) SERVER="$OPTARG" ;;
            c) CHANNEL="$OPTARG" ;;
            t) TARGET="$OPTARG" ;;
            n) NICK="$OPTARG" ;;
            p) PORT="$OPTARG" ;;
            d) DEBOUNCE="$OPTARG" ;;
            e) STARTUP_CMDS+=("$OPTARG") ;;
            E) SKIP_DEFAULTS=true ;;
            i) IRCDIR="$OPTARG" ;;
            f) CONFFILE="$OPTARG" ;;
            h) usage ;;
            ?) exit 1 ;;
        esac
    done
}

validate() {
    [[ -n "$SERVER" ]]  || die "server (-s) is required"
    [[ -n "$CHANNEL" ]] || die "channel (-c) is required"
    [[ -n "$TARGET" ]]  || die "target pane (-t) is required"
    tmux has-session -t "${TARGET%%.*}" 2>/dev/null || die "tmux target '$TARGET' not found"
    command -v ii >/dev/null || die "ii not found in PATH"
}

main() {
    # Pre-pass: extract -f before loading config
    local args=("$@")
    local OPTIND=1
    while getopts "s:c:t:n:p:d:e:Ei:f:h" opt; do
        [[ "$opt" == "f" ]] && CONFFILE="$OPTARG"
    done

    # Load config, then parse all CLI args (CLI wins)
    load_config "$CONFFILE"
    OPTIND=1
    parse_args "$@"
    validate

    log "config: server=$SERVER port=$PORT channel=$CHANNEL target=$TARGET nick=$NICK debounce=$DEBOUNCE"
}

main "$@"
```

**Step 2: Make executable and verify**

```bash
chmod +x pipe-tmux.sh
```

Run: `./pipe-tmux.sh -h`
Expected: usage text printed

Run: `./pipe-tmux.sh`
Expected: `pipe-tmux: error: server (-s) is required`

Run: `./pipe-tmux.sh -s test -c "#test" -t nonexistent:0`
Expected: `pipe-tmux: error: tmux target 'nonexistent:0' not found`

**Step 3: Commit**

```bash
git add pipe-tmux.sh
git commit -m "feat: add script skeleton with config, args, and validation"
```

---

### Task 2: IRC connection, channel join, and startup commands

**Files:**
- Modify: `pipe-tmux.sh`

**Step 1: Add cleanup trap and ii startup**

Add before `main()`:

```bash
cleanup() {
    log "cleaning up..."
    tmux pipe-pane -t "$TARGET" "" 2>/dev/null || true
    for pid in "${PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
    rm -rf "$IRCDIR"
    log "done"
}
```

**Step 2: Add connection and channel join functions**

Add before `main()`:

```bash
wait_for_connection() {
    local server_dir="$IRCDIR/$SERVER"
    local attempts=0
    log "connecting to $SERVER..."
    while [[ ! -p "$server_dir/in" ]]; do
        sleep 0.5
        attempts=$((attempts + 1))
        [[ $attempts -ge 60 ]] && die "timeout connecting to $SERVER"
    done
    log "connected to $SERVER"
}

join_channel() {
    local server_dir="$IRCDIR/$SERVER"
    echo "/j $CHANNEL" > "$server_dir/in"
    local chan_dir="$server_dir/$CHANNEL"
    local attempts=0
    log "joining $CHANNEL..."
    while [[ ! -p "$chan_dir/in" ]]; do
        sleep 0.5
        attempts=$((attempts + 1))
        [[ $attempts -ge 30 ]] && die "timeout joining $CHANNEL"
    done
    log "joined $CHANNEL"
}

run_startup() {
    if ! $SKIP_DEFAULTS; then
        log "disabling tmux status bar"
        tmux set-option -t "$TARGET" status off 2>/dev/null || true
    fi
    for cmd in "${STARTUP_CMDS[@]}"; do
        log "startup: tmux $cmd"
        eval "tmux $cmd" 2>/dev/null || log "startup command failed: tmux $cmd"
    done
}
```

**Step 3: Update main() to use these functions**

Replace the end of `main()` (after `validate`) with:

```bash
    trap cleanup EXIT

    mkdir -p "$IRCDIR"

    # Start ii in background
    ii -s "$SERVER" -p "$PORT" -n "$NICK" -i "$IRCDIR" &
    PIDS+=($!)
    log "started ii (pid $!)"

    wait_for_connection
    join_channel
    run_startup

    log "bridge ready: $TARGET <-> $CHANNEL@$SERVER"
    log "press Ctrl+C to stop"

    # Placeholder: wait for interrupt
    wait
```

**Step 4: Test against an IRC server**

Run: `./pipe-tmux.sh -s <server> -c "#test" -t pipetest:0`
Expected: connects, joins channel, prints "bridge ready", bot visible in channel.
Ctrl+C: prints "cleaning up...", "done", exits cleanly.

**Step 5: Commit**

```bash
git add pipe-tmux.sh
git commit -m "feat: add IRC connection, channel join, and startup commands"
```

---

### Task 3: Tmux to IRC output streaming with debounce

**Files:**
- Modify: `pipe-tmux.sh`

**Step 1: Add the flush function**

Add before `main()`:

```bash
flush_to_irc() {
    local text="$1"
    local irc_in="$2"
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        # Split lines longer than 450 chars
        while [[ ${#line} -gt 450 ]]; do
            echo "${line:0:450}" > "$irc_in"
            line="${line:450}"
            sleep 0.1
        done
        [[ -n "$line" ]] && echo "$line" > "$irc_in"
        sleep 0.1
    done <<< "$text"
}
```

**Step 2: Add the tmux-to-IRC streaming function**

Add before `main()`:

```bash
start_tmux_to_irc() {
    local irc_in="$IRCDIR/$SERVER/$CHANNEL/in"
    local pane_output="$IRCDIR/pane_output"
    : > "$pane_output"

    # Pipe pane output, stripping ANSI escape codes
    tmux pipe-pane -t "$TARGET" "sed -u 's/\x1b\[[^@-~]*[@-~]//g; s/\x1b[()][A-Z0-9]//g; s/\r//g' >> '$pane_output'"
    log "started tmux output capture"

    (
        local buffer=""
        while true; do
            if IFS= read -r -t "$DEBOUNCE" line; then
                buffer+="$line"$'\n'
            else
                local status=$?
                if [[ -n "$buffer" ]]; then
                    flush_to_irc "$buffer" "$irc_in"
                    buffer=""
                fi
                # Truncate file if over 1MB
                if [[ $(stat -c%s "$pane_output" 2>/dev/null || echo 0) -gt 1048576 ]]; then
                    : > "$pane_output"
                fi
                # EOF (not timeout) means pipe closed
                [[ $status -le 128 ]] && break
            fi
        done < <(tail -n 0 -f "$pane_output")
    ) &
    PIDS+=($!)
    log "started debounce loop (pid $!)"
}
```

**Step 3: Wire into main()**

In `main()`, replace the placeholder `wait` block with:

```bash
    start_tmux_to_irc

    log "press Ctrl+C to stop"
    wait
```

**Step 4: Test output streaming**

Run: `./pipe-tmux.sh -s <server> -c "#test" -t pipetest:0`
Then type commands in the `pipetest` tmux pane (e.g. `ls`, `echo hello`).
Expected: output appears in IRC channel after ~2 second pause.

**Step 5: Commit**

```bash
git add pipe-tmux.sh
git commit -m "feat: add tmux-to-IRC output streaming with debounce"
```

---

### Task 4: IRC to tmux keystroke injection

**Files:**
- Modify: `pipe-tmux.sh`

**Step 1: Add the IRC-to-tmux function**

Add before `main()`:

```bash
start_irc_to_tmux() {
    local irc_out="$IRCDIR/$SERVER/$CHANNEL/out"

    # Wait for out file to exist
    while [[ ! -f "$irc_out" ]]; do
        sleep 0.5
    done

    (
        tail -n 0 -f "$irc_out" | while IFS= read -r line; do
            # Parse ii format: YYYY-MM-DD HH:MM <nick> message
            if [[ "$line" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}\ \<([^>]+)\>\ (.*)$ ]]; then
                local sender="${BASH_REMATCH[1]}"
                local msg="${BASH_REMATCH[2]}"

                # Skip own messages
                [[ "$sender" == "$NICK" ]] && continue

                if [[ "$msg" == !* ]]; then
                    # Key sequence mode
                    local keys="${msg#!}"
                    log "keys from $sender: $keys"
                    eval "tmux send-keys -t '$TARGET' $keys"
                else
                    # Literal text + Enter
                    log "text from $sender: $msg"
                    tmux send-keys -t "$TARGET" -l "$msg"
                    tmux send-keys -t "$TARGET" Enter
                fi
            fi
        done
    ) &
    PIDS+=($!)
    log "started IRC listener (pid $!)"
}
```

**Step 2: Wire into main()**

In `main()`, add after `start_tmux_to_irc`:

```bash
    start_irc_to_tmux
```

**Step 3: Test full bridge**

Run: `./pipe-tmux.sh -s <server> -c "#test" -t pipetest:0`

Test literal text: Type `echo hello` in IRC channel.
Expected: `echo hello` + Enter keystroke appears in tmux pane, command executes, output streams back to IRC.

Test key sequences: Type `!C-c` in IRC channel.
Expected: Ctrl+C sent to tmux pane.

Test tmux hotkeys: Type `!C-a d` in IRC channel (if Ctrl+A is prefix).
Expected: Sends tmux prefix + d (detach).

**Step 4: Commit**

```bash
git add pipe-tmux.sh
git commit -m "feat: add IRC-to-tmux keystroke injection with ! prefix for key sequences"
```

---

### Task 5: End-to-end verification

**Step 1: Create a sample config file for testing**

Create `example.pipe-tmux.conf`:

```
# Example pipe-tmux config
server=irc.server.net
port=6667
channel=#test
target=pipetest:0.0
nick=pipe-tmux
debounce=2
startup=set status off
```

**Step 2: Test with config file**

Run: `./pipe-tmux.sh -f example.pipe-tmux.conf`
Expected: connects using config values.

Run: `./pipe-tmux.sh -f example.pipe-tmux.conf -n override-nick`
Expected: uses `override-nick` instead of config's `pipe-tmux`.

**Step 3: Test cleanup**

While running, press Ctrl+C.
Expected: ii killed, pipe-pane stopped, temp dir removed, "done" printed.

**Step 4: Commit example config**

```bash
git add example.pipe-tmux.conf
git commit -m "docs: add example config file"
```
