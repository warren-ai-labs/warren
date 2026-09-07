# Herdr-inspired Agent/PTY interaction contract

This note records the interaction rules that Warren should preserve when a
provider is exposed through a terminal (PTY) rather than a native Agent API.
It is based on Herdr's `agent.prompt`, `agent.send_keys`, `pane.send_text`,
`pane.send_keys`, and `pane.wait` handlers. The paths in that implementation
are intentionally not part of Warren's wire protocol; the behavioural rules
are.

## Two input paths

The terminal is the source of truth for a TUI. A client must keep these paths
separate:

1. **Prompt text** is a user message or an answer that should be inserted into
   the agent's input editor. It is sent as text, with bracketed-paste framing
   when the terminal advertises bracketed paste, followed by a separate Enter
   key.
2. **Raw keys** are navigation and control intent (`Ctrl-C`, arrows, Tab,
   Escape, and so on). They are encoded with the terminal's keyboard protocol
   and sent as key bytes. Raw keys must not be represented as prompt text.

The distinction matters for both shell and full-screen TUIs. Sending the
literal string `Enter`, or appending `\r` to every text write, can insert text
instead of submitting the prompt; sending a key name through the text path can
also be interpreted as an answer.

## Safe text submission sequence

Herdr queues a submission as two writes and completes it asynchronously:

```text
text bytes -> wait about 300 ms -> Enter bytes
```

The delay gives the provider TUI time to consume the editor update and redraw
its prompt before the submit key arrives. Warren's PTY fallback should keep
the same ordering and delay when it can do so without blocking the control
plane. A failed first write must not schedule the Enter write.

For multi-line text, use bracketed paste when enabled:

```text
ESC [200~ <text with LF converted to CR> ESC [201~ -> wait -> CR
```

When bracketed paste is disabled, send the raw text (with the provider's
normal newline rules) and still submit with a distinct Enter write. Do not
reuse this framing for a raw key sequence.

## Answers and cancellation

An interaction response is first validated against the Host-provided schema.
For a PTY-only provider, the Host then translates it into visible terminal
input:

- **Question choice:** send the visible option label when the TUI displays
  labels rather than provider-neutral IDs, then submit with the two-write
  sequence above. Keep IDs in the canonical response for validation.
- **Permission/confirmation:** send the provider's expected choice key (for
  example `y` or `n`) as a raw/text submission according to the provider
  contract; do not invent options that were absent from the event.
- **Cancel:** send one `Ctrl-C` byte (`0x03`) through the raw-key path. Do not
  send a textual answer or Enter after cancellation.

Multiple question answers are submitted in schema order. If a provider needs a
different navigation sequence, that sequence belongs in its adapter and must
be advertised as a capability; the iOS client must not guess it from prose.

## Waiting for state changes

Write completion is not proof that the TUI accepted an answer. After a
submission, wait for an observable terminal or Agent state change before
reporting success to the user:

- a changed PTY screen/revision, or
- a provider-native interaction-resolved/status event.

Herdr's `pane.wait` repeatedly reads a bounded terminal snapshot and returns
only after the requested match appears, the timeout expires, or the client
disconnects. Warren should use the same bounded polling principle for any
PTY-only fallback. A timeout is a visible, retryable failure; it is not an
implicit `Answered` event.

## What must never be inferred

Do not create a Question, Goal, Plan, or Todo event from:

- a question mark in assistant text;
- a tool name without a valid structured payload;
- a failed `request_user_input` diagnostic;
- a period of terminal inactivity; or
- a screen that merely resembles a prompt without a stable interaction ID.

Structured cards are projections of Host events. A canonical interaction must
carry its discriminator (`kind`), stable ID, version, and valid schema. A
resolved row without the original Question schema is renderable only when it
matches a previously validated request with the same ID.

## Capability and Goal boundary

The Host advertises `agent-interactions-v1` only when it can safely execute the
provider's interaction path. Warren's built-in PTY adapter currently enables
that capability for Codex, whose question labels and `y`/`n` approval keys are
known; other providers remain read-only until their prompt protocol is
explicitly implemented. A read-only card directs the user to Terminal.

Codex's app-server exposes Goal operations (`thread/goal/get`,
`thread/goal/set`, and `thread/goal/clear`). Warren currently transports Codex
through PTY/Headless, so the Host advertises `agent-goals-v1` for Codex and
uses the documented `/goal <objective>` and `/goal clear` commands as a
provider-specific fallback. Editing an existing Goal uses the TUI's dedicated
`/goal edit` prompt, clears its prefilled text with the editor's `Ctrl-U` key,
then submits the replacement objective. This avoids the `/goal <objective>`
"Replace goal?" confirmation and keeps multiline text from being appended to
the old objective. The command receipt only means the bytes were accepted by
the Host; the Goal capsule is refreshed from the observed
`thread_goal_updated`/`thread_goal_cleared` transcript event.

## Review checklist

- Is the event source explicit and structured?
- Is the interaction ID and version stable across retries?
- Are text and raw-key writes kept on separate paths?
- Is Enter sent after a short, bounded delay?
- Is terminal/provider state observed after the write?
- Does a failure remain visible and retryable?
- Is every provider-specific behaviour behind a Host capability?
