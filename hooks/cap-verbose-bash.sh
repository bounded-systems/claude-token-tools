#!/usr/bin/env bash
# PreToolUse(Bash) hook: cap the output of known-verbose commands to the last N
# lines while preserving the real exit code. Whitelisted commands only; every
# other command passes through untouched. NEVER blocks — any error path is a
# no-op (exit 0, no JSON), so the original command runs unchanged.
#
# Why: keeps multi-thousand-line test/build/validator logs from flooding
# context (the ">150k context" tax). The failing lines are almost always at the
# tail. Re-run a command piped through `cat` if you need the full log.

input=$(cat 2>/dev/null) || exit 0
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -z "$cmd" ] && exit 0

# Skip commands that already manage their own output (and our own wrapper, so
# the rewrite is never applied twice).
case "$cmd" in
  *"tail -n"*|*"| tail"*|*"| head"*|*"| less"*|*">"*|*cap-verbose*|*cap-run*) exit 0 ;;
esac

# Only rewrite these verbose commands. Extend the alternation as needed.
if ! printf '%s' "$cmd" | grep -Eq '(^| )(bun run verify|bun run regen|bun( run)? test|bun run cli validate|bun run harness/validate_|git status)'; then
  exit 0
fi

CAP=140
THRESH=160

# Emit ONE SIMPLE COMMAND: `bash <hooks dir>/cap-run.sh CAP THRESH '<original>'`.
#
# This used to inline the whole capture-and-tail pipeline as a compound command
# containing ${__n:-0}. Claude Code decides auto-backgrounding eligibility by
# parsing a Bash command into simple commands and treats a parameter expansion
# such as ${VAR} as unparseable, so every wrapped command lost that
# eligibility: at its timeout it was stopped rather than moved to the
# background. A slow, verbose command — precisely what this hook exists for —
# was therefore killed instead of backgrounded. Delegating to cap-run.sh keeps
# the rewrite parseable.
#
# cap-run.sh sits beside this script; both are deployed to <configDir>/hooks/.
here=$(dirname "$0")

# Single-quote the original command for safe embedding, escaping any embedded
# single quotes as '\'' . Pure parameter expansion, no sed.
quoted="'${cmd//\'/\'\\\'\'}'"

wrapped="bash ${here}/cap-run.sh ${CAP} ${THRESH} ${quoted}"

# updatedInput replaces the entire input object, so carry the other tool_input
# fields (description, timeout, run_in_background) through rather than dropping
# them.
jq -nc --argjson inp "$input" --arg c "$wrapped" \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",updatedInput:($inp.tool_input + {command:$c})}}' \
  2>/dev/null || exit 0
exit 0
