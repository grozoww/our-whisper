#!/usr/bin/env bash
#
# Scores the assistant mode with the real model.
#
#   ./scripts/eval-assistant.sh                     builds, then runs scripts/assistant-cases.tsv
#   ./scripts/eval-assistant.sh other.tsv           a cases file of your own
#
# Run it after any change to the assistant prompt, its instructions or its checks
# (OnDeviceRefiner+Assistant.swift, Mode.assistantInstructions) and after changing the model. The
# clipboard lookup taught this the hard way: a 2B model moves a lot on small changes to a prompt,
# and CI has no model to notice. There are two kinds of failure. Those that must never ship — the
# prompt's own sentences coming back, the request said back, an instruction planted in the
# clipboard being obeyed — make this exit non-zero. The rest are counted and listed.
#
# Choose the model, the sampling and the thinking by environment:
#
#   OURWHISPER_SELFTEST_MODEL=/path/to/model.gguf   a file other than the one the app would use.
#                                                   Without it the assistant's own model has to
#                                                   be downloaded (Models screen); nothing is
#                                                   fetched for you.
#   OURWHISPER_SELFTEST_THINK=1                     let it think first
#   OURWHISPER_SELFTEST_GREEDY=1                    greedy decoding instead of sampling
#   OURWHISPER_SELFTEST_TEMPERATURE=0.6             sampling temperature (default 1.0)
#   OURWHISPER_SELFTEST_REPEAT=3                    each case three times, on different seeds
#   OURWHISPER_SELFTEST_SEED=7                      a different starting seed
#   EVAL_BINARY=/path/to/OurWhisper                 run this build and do not build one: a copy of
#                                                   the app lets a long run go on while the source
#                                                   is being edited
#   EVAL_ANSWERS=/tmp/answers.json                  keep the answers, to read them. They are the
#                                                   test's own cases and the model's replies, so
#                                                   they contain nothing of anyone's.
#
# What is said and what is copied are in the cases file and nowhere else: the answers go to a
# temporary file this script reads and deletes, not to the log.

set -euo pipefail
cd "$(dirname "$0")/.."

CASES="${1:-scripts/assistant-cases.tsv}"
if [ -z "${EVAL_BINARY:-}" ]; then ./scripts/run.sh --build >/dev/null; fi
BINARY="${EVAL_BINARY:-build/OurWhisper.app/Contents/MacOS/OurWhisper}"
[ -x "$BINARY" ] || { echo "No build at $BINARY"; exit 1; }

OUT="$(mktemp -t ourwhisper-assistant).json"
trap 'rm -f "$OUT"' EXIT

# Launched directly rather than through `open`, so the environment arrives. The app quits itself
# when it is done; the alarm is for a machine where it does not.
env OURWHISPER_SELFTEST_ASSISTANT="$CASES" OURWHISPER_SELFTEST_OUTPUT="$OUT" \
    perl -e 'alarm 3000; exec @ARGV' "$BINARY" >/dev/null 2>&1 || true

[ -s "$OUT" ] || {
  echo "The app wrote no answers. Is the model on this Mac? Look with: ./scripts/run.sh --logs"
  exit 1
}
[ -z "${EVAL_ANSWERS:-}" ] || cp "$OUT" "$EVAL_ANSWERS"
python3 scripts/score-assistant.py "$CASES" "$OUT"
