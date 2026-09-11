#!/usr/bin/env bash
# SessionStart hook: record which Claude account is active for this session, so
# usage can be attributed per account later (the model-usage skill joins on
# session_id). Appends one JSON line. Best-effort; never blocks.
#
# PRIVACY: the log holds your account email/uuid. It lives outside any git repo
# — never copy it into a tracked tree.
#
# TWO BUGS THIS FIXES, both silent, both found on a machine that had moved its
# config dir (2026-09-11):
#
#   1. WRONG ACCOUNT. This read "$HOME/.claude.json" unconditionally. That is
#      the LEGACY default-dir account file. Once CLAUDE_CONFIG_DIR points
#      somewhere else, the live account lives at "$CLAUDE_CONFIG_DIR/.claude.json"
#      and the legacy file is a stale snapshot of whatever account was last used
#      before the move. So every session was attributed to the wrong account —
#      in the one component whose only job is attribution.
#
#   2. WROTE NOTHING AT ALL. This appended to "$HOME/.claude/session-accounts.jsonl".
#      When the config dir has moved, "$HOME/.claude/" need not exist, the
#      redirect fails, stderr is discarded and the hook exits 0. It had written
#      nothing for weeks and looked healthy the whole time.
#
# THE ACCOUNT FILE IS NOT ALWAYS INSIDE THE CONFIG DIR, and both naive fixes are
# wrong in opposite directions:
#
#   $HOME/.claude.json                -> the real legacy file, BESIDE $HOME/.claude,
#                                        not inside it
#   $HOME/.claude/.claude.json        -> may exist as a leftover from a config-dir
#                                        move, holding the NEW account at the OLD
#                                        dir's path — a trap
#   $CLAUDE_CONFIG_DIR/.claude.json   -> the live account, when the var is set
#
# So: when CLAUDE_CONFIG_DIR is set, the account file is inside it. When it is
# unset (the legacy default), the file is "$HOME/.claude.json" — one level UP
# from the config dir. Hardcoding either path alone reports the wrong account
# for the other case, silently, which is worse than reporting nothing.
#
# Best-effort by construction: every failure path exits 0. A session that cannot
# be stamped is not a reason to make someone's startup fail.

set -uo pipefail

CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
  ACCOUNT_FILE="$CLAUDE_CONFIG_DIR/.claude.json"
else
  ACCOUNT_FILE="$HOME/.claude.json"
fi

# XDG state, not the config dir: this is append-only run data, not configuration.
# Kept in one fixed place so the reader finds it whether or not the config dir
# has moved — which is bug 2 above. The model-usage skill resolves the same path
# and falls back to the legacy "$HOME/.claude/session-accounts.jsonl" so existing
# history is not orphaned.
LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/claude"
LOG="$LOG_DIR/session-accounts.jsonl"

mkdir -p "$LOG_DIR" 2>/dev/null

# Read stdin ONCE. It is a stream: a second `jq` on it gets nothing, which is how
# a hook silently records an empty session id.
input=$(cat 2>/dev/null) || exit 0
sid=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
[ -z "$sid" ] && exit 0

acct=$(jq -r '.oauthAccount.emailAddress // "?"' "$ACCOUNT_FILE" 2>/dev/null)
uuid=$(jq -r '.oauthAccount.accountUuid // "?"' "$ACCOUNT_FILE" 2>/dev/null)
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%S)

# config_dir is recorded alongside the account deliberately: credentials are
# keyed per config dir natively (the keychain holds both "Claude Code-credentials"
# and "Claude Code-credentials-<hash>", where <hash> is sha256(config dir)[0:8]),
# so it distinguishes two accounts even when the account file is unreadable, and
# it is what a multi-account audit joins on.
printf '{"ts":"%s","session_id":"%s","account":"%s","accountUuid":"%s","config_dir":"%s"}\n' \
  "$ts" "$sid" "$acct" "$uuid" "$CONFIG_DIR" >> "$LOG" 2>/dev/null
exit 0
