# prbe-codex-tap-plugin

A Codex CLI plugin that ships per-session Codex rollout transcripts to
Probe (`api.prbe.ai/webhooks/codex`) for ingestion. Runs as a session-
scoped daemon spawned by Codex's `SessionStart` hook; the daemon exits
on its own via orphan detection once Codex closes the rollout file
(Codex has no SessionEnd hook).

Zero runtime dependencies (stdlib only); Python 3.11+.

## Install

This plugin is published through the `prbe-ai` marketplace. From inside
Codex:

```
/plugin marketplace add prbe-ai/prbe-codex-tap-plugin
/plugin install prbe-codex-tap-plugin@prbe-ai
```

Then pair this laptop with your Probe workspace from a terminal. The `*/`
glob resolves to whichever version Codex installed:

```bash
cd "$(ls -d ~/.codex/plugins/cache/prbe-ai/prbe-codex-tap-plugin/*/ | tail -1)" && \
  python3 -m tap pair <pairing-token>
```

Get a pairing token from **https://dashboard.prbe.ai → Integrations → Codex**.

## How it works

```
┌─ Codex session ─────────────────────────────────────────────────────┐
│                                                                      │
│  SessionStart hook ──► spawns tap daemon (detached, crash-loop)      │
│                              │                                       │
│                              ▼                                       │
│                       every active_interval (default 60s):           │
│                       1. tail rollout JSONL (byte-offset cursor)     │
│                       2. translate RolloutItems → CC-shape events    │
│                          (see tap/sanitize.py)                       │
│                       3. build batch body, enqueue to sqlite outbox  │
│                       4. drain outbox: POST /webhooks/codex          │
│                          - 2xx → mark success                        │
│                          - 401 → halt + clear outbox                 │
│                          - 4xx (poison) → drop                       │
│                          - else → exponential backoff retry          │
│                                                                      │
│  Orphan detection ──► daemon exits when no process holds the         │
│                       rollout fd (Codex closed → session ended)      │
└──────────────────────────────────────────────────────────────────────┘
```

### Format shim

Codex writes RolloutItems (`{type, payload, timestamp}` envelope, with
variants `session_meta | response_item | turn_context | compacted | event_msg`).
The sanitizer translates each line into Anthropic-shape events that the
existing prbe-knowledge ingestion connector understands. Codex-only fields
(sandbox/network policy, per-turn `developer_instructions`, sub-agent
metadata, `MessagePhase`, structured reasoning summaries) are stashed under
a top-level `_codex_extras` key on the translated event, so nothing is
dropped on the floor — `tap/sanitize.py` documents the full mapping.

## State files

State lives at `~/.codex/state/prbe-codex-tap-plugin/` (override via
`PRBE_CODEX_TAP_PLUGIN_DIR`). The plugin code itself is managed by
Codex under `~/.codex/plugins/cache/prbe-ai/prbe-codex-tap-plugin/<version>/`;
keeping state at a stable path means version bumps don't require re-pairing.

| File | Purpose |
|------|---------|
| `.token` | Bearer token (mode 0600). Provisioned by `pair`. |
| `.config` | JSON for cadence overrides — see below. |
| `.disabled` | Presence disables the daemon entirely. |
| `.disabled_paths` | Newline-separated cwd prefixes to skip. |
| `state.db` | sqlite: file_offsets, outbox, meta. |
| `logs/<session_id>.log` | Per-session log file. |

## Cadence

The daemon is adaptive by default:

- **Active mode (60s)** while the rollout is advancing
- **Idle mode (300s)** after two consecutive empty ticks

Active resumes the moment new lines appear. Override via `.config`:

```bash
echo '{"active_interval_seconds": 30, "idle_interval_seconds": 600}' \
  > ~/.codex/state/prbe-codex-tap-plugin/.config
```

## SessionStart hook handling of nullable transcript_path

Codex's `SessionStart` payload has `transcript_path` declared nullable —
the rollout file may not yet exist on disk when the hook fires. The hook
script falls back to passing `--transcript-dir ~/.codex/sessions` to the
daemon, which scans the date-partitioned tree for a rollout matching the
session id and waits patiently (up to 30 minutes) for it to appear.

## Environment variables

| Variable | Purpose |
|----------|---------|
| `PRBE_API_BASE_URL` | Override base URL (default `https://api.prbe.ai`). |
| `PRBE_CODEX_SESSIONS_DIR` | Override `~/.codex/sessions` (testing). |
| `PRBE_CODEX_TAP_ACTIVE_INTERVAL_SECONDS` | Override active interval. |
| `PRBE_CODEX_TAP_IDLE_INTERVAL_SECONDS` | Override idle interval. |
| `PRBE_CODEX_TAP_INTERVAL_SECONDS` | Legacy single-knob — applies to both. |
| `PRBE_CODEX_TAP_PLUGIN_DIR` | Override state directory (for tests). |
| `PRBE_CODEX_TAP_TOKEN` | Override `.token` (for tests/dev). |

## Subcommands

```bash
python -m tap watch    # daemon (called by SessionStart hook)
python -m tap pair     # exchange pairing token for bearer
python -m tap status   # print local state
python -m tap revoke   # revoke device server-side + wipe local state
```

## Development

```bash
cd plugins/prbe-codex-tap-plugin
uv venv --python 3.13 .venv
.venv/bin/python -m pip install -e .
.venv/bin/python -m pytest tests/ -v
```
