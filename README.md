# prbe-ai (Codex CLI marketplace)

This repo is a Codex CLI plugin marketplace that publishes Probe's plugins.
Today it has one plugin: [`prbe-codex-tap-plugin`](./plugins/prbe-codex-tap-plugin/).

The marketplace manifest lives at `.claude-plugin/marketplace.json` —
Codex's plugin loader accepts that path alongside `.agents/plugins/marketplace.json`,
so the same outer structure works in both Claude Code and Codex.

## Install (in Codex)

```
/plugin marketplace add prbe-ai/prbe-codex-tap-plugin
/plugin install prbe-codex-tap-plugin@prbe-ai
```

Then pair the device with your Probe workspace from a terminal:

```bash
cd "$(ls -d ~/.codex/plugins/cache/prbe-ai/prbe-codex-tap-plugin/*/ | tail -1)" && \
  python3 -m tap pair <pairing-token>
```

Get a pairing token from your Probe dashboard:
**https://dashboard.prbe.ai → Integrations → Codex**.

After pairing, every new Codex session will spawn the daemon via the
SessionStart hook and ship transcripts to Probe for ingestion.

## Updates

```
/plugin marketplace update prbe-ai
/plugin install prbe-codex-tap-plugin@prbe-ai   # picks up the new version
```

Codex drops new versions in their own subdir, so existing daemons keep
running on the old code until their session ends — no mid-session
interruption.

## Repo layout

```
prbe-codex-tap-plugin/                       (this repo — the marketplace)
├── .claude-plugin/marketplace.json          # manifest Codex reads
└── plugins/
    └── prbe-codex-tap-plugin/               # the plugin itself
        ├── .codex-plugin/plugin.json
        ├── hooks/
        ├── tap/
        ├── tests/
        ├── pyproject.toml
        └── README.md
```

The plugin's own [README](./plugins/prbe-codex-tap-plugin/README.md) covers the
daemon's design, config files, env vars, and CLI subcommands.

## License

MIT.
