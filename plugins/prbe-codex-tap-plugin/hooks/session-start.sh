#!/usr/bin/env bash
# SessionStart hook for prbe-codex-tap-plugin.
#
# Reads {session_id, transcript_path, cwd} from stdin and spawns the tap
# daemon detached, wrapped in a crash-recovery loop. Wrapper PID is recorded
# in /tmp/prbe-codex-tap-watcher-<sid>.pid.
#
# Codex sets transcript_path nullable on SessionStart — the rollout file
# may not yet exist when the hook fires. When transcript_path is empty/null
# we pass --transcript-dir to the daemon, which scans
# ~/.codex/sessions/YYYY/MM/DD/ for a rollout matching session_id with
# patient retry. The daemon takes care of the resolution either way.
#
# Codex has no SessionEnd hook, so there is no teardown counterpart. The
# daemon exits on its own via orphan detection (lsof on the rollout file)
# once Codex closes the rollout.

set -euo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
PLUGIN_DIR="${PRBE_CODEX_TAP_PLUGIN_DIR:-$HOME/.codex/state/prbe-codex-tap-plugin}"
LOG_DIR="$PLUGIN_DIR/logs"
mkdir -p "$LOG_DIR"

HOOK_INPUT="$(cat)"
SESSION_ID=$(printf '%s' "$HOOK_INPUT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("session_id",""))' 2>/dev/null || echo "")
TRANSCRIPT_PATH=$(printf '%s' "$HOOK_INPUT" | python3 -c 'import json,sys; v=json.load(sys.stdin).get("transcript_path"); print(v if isinstance(v,str) else "")' 2>/dev/null || echo "")
CWD=$(printf '%s' "$HOOK_INPUT" | python3 -c 'import json,sys,os; print(json.load(sys.stdin).get("cwd") or os.getcwd())' 2>/dev/null || echo "")

# session_id is required; transcript_path may be null on SessionStart.
if [ -z "$SESSION_ID" ]; then
    printf '{"continue": true}\n'
    exit 0
fi

LOG_FILE="${LOG_DIR}/${SESSION_ID}.log"

# Killswitch: presence of .disabled disables the daemon entirely.
if [ -f "$PLUGIN_DIR/.disabled" ]; then
    echo "[$(date -u +%FT%TZ)] killswitch active, skipping" >>"$LOG_FILE"
    printf '{"continue": true}\n'
    exit 0
fi

# Without a token there's nothing to authenticate with. Surface once and no-op.
if [ ! -f "$PLUGIN_DIR/.token" ] && [ -z "${PRBE_CODEX_TAP_TOKEN:-}" ]; then
    echo "[$(date -u +%FT%TZ)] no token at $PLUGIN_DIR/.token; run 'python -m tap pair <token>' first" >>"$LOG_FILE"
    printf '{"continue": true}\n'
    exit 0
fi

PID_FILE="/tmp/prbe-codex-tap-watcher-${SESSION_ID}.pid"

# If a daemon is already running for this session_id (e.g. resumed session),
# don't spawn another.
if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    printf '{"continue": true}\n'
    exit 0
fi

# Resolve Python interpreter — prefer plugin-local venv.
PY="$PLUGIN_ROOT/.venv/bin/python3"
[ -x "$PY" ] || PY="$(command -v python3 || true)"
if [ -z "$PY" ] || [ ! -x "$PY" ]; then
    echo "[$(date -u +%FT%TZ)] no python3 found, daemon disabled" >>"$LOG_FILE"
    printf '{"continue": true}\n'
    exit 0
fi

# Pick the daemon transcript-locator mode based on whether the hook payload
# had transcript_path. The daemon accepts EITHER --transcript <file> OR
# --transcript-dir <root> + --session-id <id>; the dir mode scans the date-
# partitioned tree for a rollout matching the session id and waits patiently.
TRANSCRIPT_DIR="${PRBE_CODEX_SESSIONS_DIR:-$HOME/.codex/sessions}"
if [ -n "$TRANSCRIPT_PATH" ]; then
    TRANSCRIPT_ARGS=(--transcript "$TRANSCRIPT_PATH")
else
    TRANSCRIPT_ARGS=(--transcript-dir "$TRANSCRIPT_DIR")
fi

# Crash-recovery wrapper: respawn up to 5 times per minute. Self-terminates
# when /tmp/prbe-codex-tap-watcher-<sid>.shutdown exists; useful for a manual
# `tap status --stop` or test harness, even though Codex itself never touches
# it.
#
# Why a SIGTERM trap that forwards to the python child: macOS doesn't ship
# `setsid` so we can't put the wrapper + daemon in their own process group
# and rely on `kill -TERM -<pgid>` to take down both at once. Instead we
# detach via `nohup ... & disown` (POSIX-portable) and have the wrapper
# bash forward SIGTERM/SIGINT explicitly to the python child it spawns.
WRAPPER_SCRIPT='
SID="$1"; CWD="$2"; PY="$3"; ROOT="$4"; LOG="$5"; shift 5
SHUTDOWN="/tmp/prbe-codex-tap-watcher-${SID}.shutdown"
RESTART_COUNT=0
WINDOW_START=$(date +%s)
CHILD_PID=""
trap '\''[ -n "$CHILD_PID" ] && kill -TERM "$CHILD_PID" 2>/dev/null; exit 0'\'' TERM INT
while true; do
    [ -f "$SHUTDOWN" ] && exit 0
    NOW=$(date +%s)
    if [ $((NOW - WINDOW_START)) -ge 60 ]; then
        WINDOW_START=$NOW
        RESTART_COUNT=0
    fi
    if [ "$RESTART_COUNT" -ge 5 ]; then
        echo "[$(date -u +%FT%TZ)] tap: too many restarts in 1min, giving up" >>"$LOG"
        exit 1
    fi
    "$PY" -m tap watch --session-id "$SID" --cwd "$CWD" --plugin-root "$ROOT" "$@" >>"$LOG" 2>&1 &
    CHILD_PID=$!
    wait "$CHILD_PID" 2>/dev/null || true
    CHILD_PID=""
    [ -f "$SHUTDOWN" ] && exit 0
    RESTART_COUNT=$((RESTART_COUNT + 1))
    sleep 5
done
'

# Detach the wrapper. nohup ignores SIGHUP so it survives Codex's exit; `&`
# backgrounds it; `disown` removes it from this shell's job table so the
# parent (this hook) can exit cleanly without reaping it.
PYTHONPATH="$PLUGIN_ROOT" \
    nohup /bin/bash -c "$WRAPPER_SCRIPT" wrapper \
    "$SESSION_ID" "$CWD" "$PY" "$PLUGIN_ROOT" "$LOG_FILE" "${TRANSCRIPT_ARGS[@]}" \
    </dev/null >>"$LOG_FILE" 2>&1 &
WRAPPER_PID=$!
disown
echo "$WRAPPER_PID" >"$PID_FILE"

printf '{"continue": true}\n'
