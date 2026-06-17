---
name: model-usage
description: Audit Claude Code token usage by model from local session transcripts (Bun + Zod), and optionally apply token-saving config changes (default model, subagent model, earlier compaction). Use when the user asks to check model/usage history, verify which model is driving spend, audit token consumption, or tune settings to reduce usage.
---

# model-usage

Reconstructs the per-model token split from **ground truth** — the `usage` block on
every assistant turn under `$CLAUDE_CONFIG_DIR/projects/**/*.jsonl` — instead of
trusting the `/stats` screen. Then recommends (and can apply) token-saving config.

Reads only model names + token counts. Never emits conversation content.

## Run it

Bun is at `~/.bun/bin/bun` (not always on PATH). First run installs `zod` locally:

```bash
cd ~/.claude/skills/model-usage && ~/.bun/bin/bun install
~/.bun/bin/bun run ~/.claude/skills/model-usage/audit.ts            # report
~/.bun/bin/bun run ~/.claude/skills/model-usage/audit.ts --days=30  # window
~/.bun/bin/bun run ~/.claude/skills/model-usage/audit.ts --by-repo   # collapse worktrees → repo
~/.bun/bin/bun run ~/.claude/skills/model-usage/audit.ts --by-project # per project (cwd)
~/.bun/bin/bun run ~/.claude/skills/model-usage/audit.ts --by-account # per Claude account (needs stamp-account SessionStart hook)
~/.bun/bin/bun run ~/.claude/skills/model-usage/audit.ts --json     # machine-readable
```

## Changing config

`--apply` merges the recommended keys into `~/.claude/settings.json` (the writable,
read+merged user-settings file — the nix `$CLAUDE_CONFIG_DIR/settings.json` is
read-only). **Always run the report first, show the user the recommended patch, and
get explicit confirmation before running `--apply`** (it modifies a config file):

```bash
~/.bun/bin/bun run ~/.claude/skills/model-usage/audit.ts --apply
```

Recommendation logic:
- Opus spend share > 50% **and** default ≠ sonnet → recommend `model: sonnet`
  (the single biggest lever; escalate to Opus 4.8 200k — not 1M — on demand).
- Fills in `effortLevel: medium`, `autoCompactEnabled`, `skillListingMaxDescChars`,
  `fastModePerSessionOptIn`, and the Haiku-subagent / 70%-compaction env vars if unset.

Caveats the skill prints and you should relay:
- The `$` column is a **list-price estimate**, not the user's subscription bill — use
  it for relative share only.
- A model chosen via `/model` persists in `~/.claude.json` (runtime) and can override
  `settings.json`; tell the user to run `/model → Sonnet` once to align.
- Permanent home is the **ai-home** nix config; after `--apply`, the keys should be
  copied there and applied via `prx home update`.
```
