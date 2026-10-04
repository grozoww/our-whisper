#!/usr/bin/env bash
#
# Scores the lookup that finds "paste the clipboard" in a sentence, with the real model.
#
#   ./scripts/eval-clipboard.sh                 builds, then runs scripts/clipboard-requests.tsv
#   ./scripts/eval-clipboard.sh other.tsv       a file of your own: "P<TAB>sentence" or "N<TAB>sentence"
#
# Run it after any change to OnDeviceRefiner.requestExamples, requestInstructions or
# requestPrompt. That model moves a lot on small changes to them — dropping examples from 24 to 8
# took false pastes from 0 to 6 in 35 — and nothing else in the repo can notice, because CI has no
# 2.8 GB file. Needs the cleanup model downloaded (launch the app once).
#
# Prints what was found, what was pasted that should not have been, and every sentence it got
# wrong. A false paste is the expensive error: it puts the clipboard into a sentence that never
# asked for it. A miss costs the person saying it again.

set -euo pipefail
cd "$(dirname "$0")/.."

FILE="${1:-scripts/clipboard-requests.tsv}"
./scripts/run.sh --build >/dev/null
BINARY="build/OurWhisper.app/Contents/MacOS/OurWhisper"
[ -x "$BINARY" ] || { echo "No build at $BINARY"; exit 1; }

SENTENCES="$(grep -v '^#' "$FILE" | awk -F'\t' 'NF >= 2 { printf "%s%s", sep, $2; sep = "||" }')"
START="$(date '+%Y-%m-%d %H:%M:%S')"

# Launched directly rather than through `open`, so the environment arrives. A one-line clipboard
# keeps every result on one log line. The app quits itself when it is done; the alarm is for a
# machine where it does not.
env OURWHISPER_SELFTEST_CLIPBOARD="TypeError: x is undefined" \
    OURWHISPER_SELFTEST_CLEANUP="$SENTENCES" \
    perl -e 'alarm 600; exec @ARGV' "$BINARY" >/dev/null 2>&1 || true

LOG="$(/usr/bin/log show --start "$START" --info \
  --predicate 'subsystem == "com.grozoww.ourwhisper" AND eventMessage CONTAINS "RESULT 1"' \
  --style compact 2>/dev/null)"
[ -n "$LOG" ] || { echo "The app logged no results. Is the cleanup model downloaded?"; exit 1; }

found=0; missed=0; falsePaste=0; clean=0; failures=""
while IFS=$'\t' read -r label sentence; do
  case "$label" in P|N) ;; *) continue ;; esac
  line="$(printf '%s\n' "$LOG" | grep -F "\"$sentence\" -> " | head -1 || true)"
  # What the pipeline produced, before the clipboard went in: the marker is the answer.
  produced="${line#*\" -> }"; produced="${produced%% | pasted:*}"
  if [[ "$produced" == *"[[CLIPBOARD]]"* ]]; then pasted=1; else pasted=0; fi

  if [ -z "$line" ]; then failures+=$'\n'"  no result: $sentence"
  elif [ "$label" = P ] && [ $pasted = 1 ]; then found=$((found + 1))
  elif [ "$label" = P ]; then missed=$((missed + 1)); failures+=$'\n'"  missed: $sentence"
  elif [ $pasted = 1 ]; then falsePaste=$((falsePaste + 1)); failures+=$'\n'"  FALSE PASTE: $sentence"
  else clean=$((clean + 1)); fi
done < "$FILE"

echo "found $found of $((found + missed)) requests; pasted into $falsePaste of $((falsePaste + clean)) sentences that were not asking"
[ -z "$failures" ] || printf '%s\n' "${failures#$'\n'}"
[ "$falsePaste" -eq 0 ]
