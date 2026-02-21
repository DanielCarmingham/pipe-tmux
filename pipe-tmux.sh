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

wait_for_connection() {
    local server_dir="$IRCDIR/$SERVER"
    local attempts=0
    log "connecting to $SERVER..."
    while [[ ! -p "$server_dir/in" ]]; do
        sleep 0.5
        attempts=$((attempts + 1))
        [[ $attempts -ge 60 ]] && die "timeout connecting to $SERVER"
    done
    # Wait for server welcome before sending commands
    local out="$server_dir/out"
    attempts=0
    while ! grep -q "Welcome to" "$out" 2>/dev/null; do
        sleep 0.5
        attempts=$((attempts + 1))
        [[ $attempts -ge 60 ]] && die "timeout waiting for server welcome"
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

    start_tmux_to_irc
    start_irc_to_tmux

    log "press Ctrl+C to stop"
    wait
}

main "$@"
