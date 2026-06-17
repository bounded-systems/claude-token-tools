#!/usr/bin/env bash
# SessionStart hook: record which Claude account is active for this session, so
# usage can be attributed per account later (the model-usage skill joins on
# session_id). Appends one JSON line. Best-effort; never blocks.
#
# PRIVACY: the log holds your account email/uuid. It lives at ~/.claude/ (not a
# git repo) — never copy it into a tracked tree.

input=$(cat 2>/dev/null) || exit 0
sid=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
[ -z "$sid" ] && exit 0

acct=$(jq -r '.oauthAccount.emailAddress // "?"' "$HOME/.claude.json" 2>/dev/null)
uuid=$(jq -r '.oauthAccount.accountUuid // "?"' "$HOME/.claude.json" 2>/dev/null)
ts=$(date -Iseconds 2>/dev/null || date +%Y-%m-%dT%H:%M:%S)

printf '{"ts":"%s","session_id":"%s","account":"%s","accountUuid":"%s"}\n' \
  "$ts" "$sid" "$acct" "$uuid" >> "$HOME/.claude/session-accounts.jsonl" 2>/dev/null
exit 0
