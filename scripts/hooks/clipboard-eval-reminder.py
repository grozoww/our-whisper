#!/usr/bin/env python3
"""PostToolUse hook: after the clipboard lookup is edited, remind the agent to measure it.

The lookup in OnDeviceRefiner (the examples, the question and the parsing of the answer) is tuned
against a real 2B model, and that model moves a lot on small changes: going from 24 examples to 8
took false pastes from 0 to 6 in 35 sentences. Nothing in CI can notice, because CI has no model.
This only reminds — the eval needs the 2.8 GB model and about a minute, so running it on every
keystroke-sized edit would be the wrong trade — and it stays silent for every other file.

Input is the hook JSON on stdin. Output, when it fires, is JSON with `additionalContext`, which
reaches the agent as context for its next step.
"""
import json
import re
import sys

LOOKUP_FILE = "Sources/Core/Refinement/OnDeviceRefiner.swift"
EXAMPLES_FILE = "scripts/clipboard-requests.tsv"

# What marks an edit as touching the lookup rather than the cleanup or the download code.
LOOKUP_EDIT = re.compile(
    r'PASTE:|COPY:|OTHER:|"NONE"|requestExamples|requestInstructions|requestPrompt|'
    r"clipboardRequest|request\(from|warmUpClipboardLookup"
)

REMINDER = (
    "You edited the clipboard lookup, which is tuned against a real 2B model that moves a lot on "
    "small changes (24 examples to 8 took false pastes from 0 to 6 in 35 sentences), and CI has no "
    "model to notice. Before you finish, run ./scripts/eval-clipboard.sh and report both numbers. "
    "It exits non-zero on any false paste, and a false paste is the error that matters: it puts "
    "the clipboard into a sentence that never asked for it. Last measured: found 41 of 43 "
    "requests, pasted into 0 of 55 others. If you changed scripts/clipboard-requests.tsv, "
    "say what you changed and why."
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

    if path.endswith(EXAMPLES_FILE):
        fires = True
    elif path.endswith(LOOKUP_FILE):
        text = edited_text(payload.get("tool_name", ""), tool_input)
        # A whole-file write cannot be told apart from a change to the lookup, so it reminds.
        fires = text is None or bool(LOOKUP_EDIT.search(text))
    else:
        fires = False

    if fires:
        print(json.dumps({
            "hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": REMINDER}
        }))


main()
