#!/usr/bin/env python3
"""PostToolUse hook: after the assistant prompt is edited, remind the agent to measure it.

The assistant's prompt, instructions and answer checks are tuned against a real model, and the
clipboard lookup next to it showed how much a small change moves one: going from 24 examples to 8
took false pastes from 0 to 6 in 35 sentences. Nothing in CI can notice, because CI has no model.
This only reminds — the eval needs the 4.6 GB model and a few minutes — and it stays silent for
every other file.

Input is the hook JSON on stdin. Output, when it fires, is JSON with `additionalContext`, which
reaches the agent as context for its next step.
"""
import json
import re
import sys

ASSISTANT_FILE = "Sources/Core/Refinement/OnDeviceRefiner+Assistant.swift"
MODE_FILE = "Sources/Core/Modes/Mode.swift"
CASES_FILE = "scripts/assistant-cases.tsv"

# What marks an edit to Mode.swift as touching the assistant's instructions and not a mode's colour.
INSTRUCTIONS_EDIT = re.compile(r"assistantInstructions|writing assistant|static let ask")

REMINDER = (
    "You edited the assistant's prompt, instructions or cases, which are tuned against a real model "
    "that moves a lot on small changes, and CI has no model to notice. Before you finish, run "
    "OURWHISPER_SELFTEST_MODEL=<the E4B file> ./scripts/eval-assistant.sh and report what it prints. "
    "It exits non-zero on what must never ship: the prompt's own sentences coming back, the request "
    "said back, an instruction planted in the clipboard being obeyed, a loop. Last measured on E4B: "
    "0 of those in 588 answers, and E2B obeyed the planted Russian instruction in 5 runs of 5. If you "
    "changed scripts/assistant-cases.tsv, say what you changed and why."
)


def edited_text(tool_name, tool_input):
    """Everything the tool put in or took out, or None when it replaced a whole file."""
    if tool_name == "Write":
        return None
    if tool_name == "MultiEdit":
        return " ".join(
            f"{e.get('old_string', '')} {e.get('new_string', '')}" for e in tool_input.get("edits", [])
        )
    return f"{tool_input.get('old_string', '')} {tool_input.get('new_string', '')}"


def main():
    try:
        payload = json.load(sys.stdin)
    except (ValueError, OSError):
        return

    tool_input = payload.get("tool_input") or {}
    path = tool_input.get("file_path") or ""

    if path.endswith(CASES_FILE) or path.endswith(ASSISTANT_FILE):
        fires = True
    elif path.endswith(MODE_FILE):
        text = edited_text(payload.get("tool_name", ""), tool_input)
        fires = text is None or bool(INSTRUCTIONS_EDIT.search(text))
    else:
        fires = False

    if fires:
        print(json.dumps({
            "hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": REMINDER}
        }))


main()
