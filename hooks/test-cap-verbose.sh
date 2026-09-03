#!/usr/bin/env bash
# Tests for cap-verbose-bash.sh + cap-run.sh. Pure: no network, no Claude Code,
# no writes outside mktemp. Run with:  bash hooks/test-cap-verbose.sh
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
HOOK="$here/cap-verbose-bash.sh"
RUN="$here/cap-run.sh"
pass=0; fail=0

ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s — %s\n' "$1" "$2"; }

emit() { # emit <command> -> rewritten command, or empty if not rewritten
  jq -nc --arg c "$1" '{tool_input:{command:$c}}' | bash "$HOOK" \
    | jq -r '.hookSpecificOutput.updatedInput.command // empty' 2>/dev/null
}

echo "matching:"
for c in "bun run verify" "bun test" "bun run test" "bun run regen" \
         "bun run cli validate" "git status"; do
  [ -n "$(emit "$c")" ] && ok "rewrites: $c" || bad "rewrites: $c" "no rewrite"
done

echo "not matching:"
for c in "ls -la" "cargo build" "bun run dev" "echo hi"; do
  [ -z "$(emit "$c")" ] && ok "passes through: $c" || bad "passes through: $c" "was rewritten"
done

echo "idempotence (never wrap twice):"
once=$(emit "bun test")
[ -z "$(emit "$once")" ] && ok "already-wrapped command is left alone" \
  || bad "idempotence" "wrapped a second time"

echo "auto-background eligibility:"
# Claude Code parses a Bash command into simple commands to decide whether it
# may be moved to the background at its timeout, and treats a parameter
# expansion such as ${VAR} as unparseable. The rewrite must not introduce one,
# or every wrapped command gets stopped at its timeout instead of backgrounded.
case "$once" in
  *'${'*) bad "no \${...} in rewrite" "found parameter expansion: $once" ;;
  *)      ok "no \${...} in rewrite" ;;
esac
# ...and it must stay a single simple command: one word plus arguments.
case "$once" in
  *';'*|*'&&'*|*'||'*|*'|'*|*'{'*) bad "single simple command" "compound: $once" ;;
  *) ok "single simple command" ;;
esac

echo "input passthrough:"
desc=$(jq -nc '{tool_input:{command:"bun test",description:"d",timeout:5000}}' \
  | bash "$HOOK" | jq -r '.hookSpecificOutput.updatedInput | "\(.description):\(.timeout)"')
[ "$desc" = "d:5000" ] && ok "description and timeout carried through" \
  || bad "input passthrough" "got '$desc', want 'd:5000'"

echo "quoting:"
q=$(emit "bun test --grep 'a b'")
case "$q" in *"'\\''a b'\\''"*) ok "embedded single quotes escaped" ;;
             *) bad "quoting" "got: $q" ;; esac

echo "cap-run behaviour:"
bash "$RUN" 140 160 'echo hi; exit 7' >/dev/null 2>&1
[ $? -eq 7 ] && ok "exit code preserved (short output)" || bad "exit code (short)" "not 7"
bash "$RUN" 140 160 'for i in $(seq 1 300); do echo l$i; done; exit 3' >/dev/null 2>&1
[ $? -eq 3 ] && ok "exit code preserved (capped output)" || bad "exit code (capped)" "not 3"
lines=$(bash "$RUN" 140 160 'for i in $(seq 1 300); do echo l$i; done' | wc -l | tr -d ' ')
[ "$lines" = "141" ] && ok "caps to 140 lines + notice" || bad "cap size" "got $lines lines, want 141"
short=$(bash "$RUN" 140 160 'echo one; echo two' | wc -l | tr -d ' ')
[ "$short" = "2" ] && ok "short output uncapped" || bad "short output" "got $short lines"
merged=$(bash "$RUN" 140 160 'echo out; echo err >&2' 2>/dev/null | tr '\n' ' ')
[ "$merged" = "out err " ] && ok "stderr merged into output" || bad "stderr merge" "got '$merged'"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
