#!/usr/bin/env bash
# Weekly local model-usage audit (report-only — never applies config).
# Writes the full JSON rollup and posts a macOS notification with the Opus
# spend share. Wired as a launchd.user.agent via the claude-token-tools
# home-manager module.
#
# Resolution order:
#   1. Pre-built bundle (audit.bundle.js) — no node_modules needed.
#   2. Source (audit.ts) + bun install — best-effort; skipped if bun absent.
# Checks ~/.config/claude/skills/model-usage/ (nix-managed) first, then
# ~/.claude/skills/model-usage/ (writable working copy / nix symlink).

BUN="$HOME/.bun/bin/bun"
[ -x "$BUN" ] || exit 0

resolve_script() {
  for dir \
    in "$HOME/.config/claude/skills/model-usage" \
       "$HOME/.claude/skills/model-usage"; do
    if [ -f "$dir/audit.bundle.js" ]; then echo "$dir/audit.bundle.js"; return; fi
    if [ -f "$dir/audit.ts" ]; then
      [ -d "$dir/node_modules" ] || ( cd "$dir" && "$BUN" install >/dev/null 2>&1 )
      echo "$dir/audit.ts"; return
    fi
  done
}

SCRIPT=$(resolve_script)
[ -n "$SCRIPT" ] || exit 0

OUT="$HOME/.claude/model-usage-latest.json"
if ! "$BUN" run "$SCRIPT" --json > "$OUT" 2>/dev/null; then
  osascript -e 'display notification "audit run failed — see ~/.claude/model-usage-audit.err" with title "Claude weekly usage audit"' 2>/dev/null
  exit 0
fi

share=$(jq -r '.totals.opusSharePct // "?"' "$OUT" 2>/dev/null)
spend=$(jq -r '.totals.estSpend // "?"' "$OUT" 2>/dev/null)
osascript -e "display notification \"Opus ${share}% of est spend (\$${spend}); full report in ~/.claude/model-usage-latest.json\" with title \"Claude weekly usage audit\"" 2>/dev/null
exit 0
