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

ansi_to_irc() {
    # Convert ANSI escape codes to IRC color/formatting codes
    # IRC: \x03FG[,BG] for color, \x02 bold, \x0F reset, \x1D italic, \x1F underline
    perl -pe '
        # Bold
        s/\x1b\[1m/\x02/g;
        # Italic
        s/\x1b\[3m/\x1d/g;
        # Underline
        s/\x1b\[4m/\x1f/g;
        # Reset
        s/\x1b\[0?m/\x0f/g;
        # Foreground colors: ANSI 30-37 -> IRC
        s/\x1b\[30m/\x0301/g;  # black
        s/\x1b\[31m/\x0304/g;  # red
        s/\x1b\[32m/\x0303/g;  # green
        s/\x1b\[33m/\x0308/g;  # yellow
        s/\x1b\[34m/\x0302/g;  # blue
        s/\x1b\[35m/\x0306/g;  # magenta
        s/\x1b\[36m/\x0310/g;  # cyan
        s/\x1b\[37m/\x0300/g;  # white
        # Default foreground
        s/\x1b\[39m/\x0f/g;
        # Bright/bold foreground: ANSI 90-97 -> IRC
        s/\x1b\[90m/\x0314/g;  # bright black (grey)
        s/\x1b\[91m/\x0305/g;  # bright red
        s/\x1b\[92m/\x0309/g;  # bright green
        s/\x1b\[93m/\x0308/g;  # bright yellow
        s/\x1b\[94m/\x0312/g;  # bright blue
        s/\x1b\[95m/\x0313/g;  # bright magenta
        s/\x1b\[96m/\x0311/g;  # bright cyan
        s/\x1b\[97m/\x0300/g;  # bright white
        # Combined sequences like \x1b[1;31m (bold+color)
        s/\x1b\[1;30m/\x02\x0301/g;
        s/\x1b\[1;31m/\x02\x0304/g;
        s/\x1b\[1;32m/\x02\x0303/g;
        s/\x1b\[1;33m/\x02\x0308/g;
        s/\x1b\[1;34m/\x02\x0302/g;
        s/\x1b\[1;35m/\x02\x0306/g;
        s/\x1b\[1;36m/\x02\x0310/g;
        s/\x1b\[1;37m/\x02\x0300/g;
        # Strip any remaining ANSI sequences we do not convert
        s/\x1b\[[0-9;]*[a-zA-Z]//g;
        s/\x1b\][^\x07]*\x07//g;
        s/\x1b\([A-Z0-9]//g;
        s/\x1b[=>]//g;
        s/\r//g;
    '
}

flush_to_irc() {
    local text="$1"
    local irc_in="$2"
    # Convert ANSI colors to IRC colors
    text=$(printf '%s\n' "$text" | ansi_to_irc)
    local buf=""
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if [[ -z "$buf" ]]; then
            buf="$line"
        elif [[ $(( ${#buf} + 3 + ${#line} )) -le 450 ]]; then
            # Fits in current message, accumulate with separator
            buf="$buf | $line"
        else
            # Would exceed limit, send current buffer and start new one
            echo "$buf" > "$irc_in"
            sleep 0.1
            buf="$line"
        fi
        # Split if single line exceeds 450
        while [[ ${#buf} -gt 450 ]]; do
            echo "${buf:0:450}" > "$irc_in"
            sleep 0.1
            buf="${buf:450}"
        done
    done <<< "$text"
    # Send remaining buffer
    [[ -n "$buf" ]] && echo "$buf" > "$irc_in"
}

start_tmux_to_irc() {
    local irc_in="$IRCDIR/$SERVER/$CHANNEL/in"

    (
        # Capture initial scrollback state
        local prev
        prev=$(tmux capture-pane -t "$TARGET" -e -p -S - 2>/dev/null) || true
        local prev_count
        prev_count=$(printf '%s\n' "$prev" | wc -l)

        while true; do
            sleep 0.5

            local curr
            curr=$(tmux capture-pane -t "$TARGET" -e -p -S - 2>/dev/null) || break
            local curr_count
            curr_count=$(printf '%s\n' "$curr" | wc -l)

            # No change
            [[ "$curr" == "$prev" ]] && continue

            # Something changed, debounce until stable
            local last_change=$SECONDS
            while (( SECONDS - last_change < DEBOUNCE )); do
                sleep 0.5
                local check
                check=$(tmux capture-pane -t "$TARGET" -e -p -S - 2>/dev/null) || break 2
                if [[ "$check" != "$curr" ]]; then
                    curr="$check"
                    curr_count=$(printf '%s\n' "$curr" | wc -l)
                    last_change=$SECONDS
                fi
            done

            # Stable - extract and send new lines
            if [[ $curr_count -gt $prev_count ]]; then
                local new_lines
                new_lines=$(printf '%s\n' "$curr" | tail -n +$((prev_count + 1)))
                # Trim trailing whitespace and skip empty lines
                new_lines=$(printf '%s\n' "$new_lines" | sed 's/[[:space:]]*$//; /^$/d')
                if [[ -n "$new_lines" ]]; then
                    flush_to_irc "$new_lines" "$irc_in"
                fi
            fi

            prev="$curr"
            prev_count=$curr_count
        done
    ) &
    PIDS+=($!)
    log "started output capture (pid $!)"
}

start_irc_to_tmux() {
    local irc_out="$IRCDIR/$SERVER/$CHANNEL/out"

    # Wait for out file to exist
    while [[ ! -f "$irc_out" ]]; do
        sleep 0.5
    done

    (
        tail -n 0 -f "$irc_out" | while IFS= read -r line; do
            # Parse ii format: TIMESTAMP <nick> message (timestamp may be unix or YYYY-MM-DD HH:MM)
            if [[ "$line" =~ ^[0-9]+\ \<([^>]+)\>\ (.*)$ ]] || [[ "$line" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}\ \<([^>]+)\>\ (.*)$ ]]; then
                # Handle both timestamp formats
                local sender="${BASH_REMATCH[1]}"
                local msg="${BASH_REMATCH[2]}"
                [[ -z "$sender" ]] && sender="${BASH_REMATCH[3]}" && msg="${BASH_REMATCH[4]}"

                # Skip own messages
                [[ "$sender" == "$NICK" ]] && continue

                if [[ "$msg" == !* ]]; then
                    # Key sequence mode
                    local keys="${msg#!}"
                    log "keys from $sender: $keys"
                    if [[ "$keys" == *'\x'* ]] || [[ "$keys" == *'\e'* ]]; then
                        # Raw escape sequences: interpret \x1b, \e, \n, etc.
                        local interpreted
                        interpreted=$(printf '%b' "$keys")
                        tmux send-keys -t "$TARGET" -l "$interpreted"
                    else
                        # Tmux key names: C-c, Up, Enter, etc.
                        eval "tmux send-keys -t '$TARGET' $keys"
                    fi
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
