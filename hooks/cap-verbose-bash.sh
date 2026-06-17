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
  *"tail -n"*|*"| tail"*|*"| head"*|*"| less"*|*">"*|*cap-verbose*) exit 0 ;;
esac

# Only rewrite these verbose commands. Extend the alternation as needed.
if ! printf '%s' "$cmd" | grep -Eq '(^| )(bun run verify|bun run regen|bun( run)? test|bun run cli validate|bun run harness/validate_|git status)'; then
  exit 0
fi

CAP=140
THRESH=160
# Run the original, capture combined output to a temp file, print a one-line
# truncation notice + last CAP lines only when output exceeds THRESH, then exit
# with the original status. No PIPESTATUS, so it is correct under bash and zsh.
wrapped="__f=\$(mktemp); { ${cmd} ; } >\"\$__f\" 2>&1; __rc=\$?; __n=\$(wc -l <\"\$__f\" | tr -d ' '); if [ \"\${__n:-0}\" -gt ${THRESH} ]; then echo \"[output capped by hook: last ${CAP} of \$__n lines — re-run piped through cat for the full log]\"; tail -n ${CAP} \"\$__f\"; else cat \"\$__f\"; fi; rm -f \"\$__f\"; exit \$__rc"

jq -nc --arg c "$wrapped" '{hookSpecificOutput:{hookEventName:"PreToolUse",updatedInput:{command:$c}}}' 2>/dev/null || exit 0
exit 0
