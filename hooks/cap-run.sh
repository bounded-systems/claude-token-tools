#!/usr/bin/env bash
# Run a command with its output capped to the last CAP lines when the output
# exceeds THRESH lines, preserving the real exit code.
#
# Invoked only by cap-verbose-bash.sh, which rewrites a matching Bash tool call
# into a single simple command:
#
#   bash <hooks dir>/cap-run.sh CAP THRESH 'original command'
#
# Why this lives in its own file rather than inline in the rewrite: Claude Code
# decides whether a Bash command is eligible for auto-backgrounding by parsing
# it into simple commands, and treats a parameter expansion such as ${VAR} as
# unparseable (see docs, Tools reference — Background commands). The previous
# inline wrapper was a compound command containing ${__n:-0}, so every command
# it wrapped became ineligible: instead of being moved to the background at its
# timeout, it was stopped. That inverted the intent for exactly the slow,
# verbose commands the cap exists to serve. Emitting one simple command keeps
# the eligibility intact.
set -u

CAP=${1:?usage: cap-run.sh CAP THRESH COMMAND}
THRESH=${2:?usage: cap-run.sh CAP THRESH COMMAND}
CMD=${3:?usage: cap-run.sh CAP THRESH COMMAND}

# If the temp file cannot be created, run the command unchanged rather than
# failing the tool call.
f=$(mktemp) || exec bash -c "$CMD"

bash -c "$CMD" >"$f" 2>&1
rc=$?

n=$(wc -l <"$f" | tr -d ' ')
[ -n "$n" ] || n=0

if [ "$n" -gt "$THRESH" ]; then
  printf '[output capped by hook: last %s of %s lines — re-run piped through cat for the full log]\n' "$CAP" "$n"
  tail -n "$CAP" "$f"
else
  cat "$f"
fi

rm -f "$f"
exit "$rc"
