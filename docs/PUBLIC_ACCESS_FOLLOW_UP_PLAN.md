# Public Access Follow-up Plan

## Scope

This follow-up stays in Warren. It uses the gnar v1.7 worker contract and does
not migrate existing system gnar credentials or change the gnar repository.

## Root causes

1. The daemon currently starts whichever gnar binary it finds without a Warren-
   owned credential directory, so an embedded binary would share the system
   gnar account store.
2. Save & Test clears the bootstrap fields immediately and treats the first
   tunnel readiness window as the authentication result. A successful login can
   therefore be shown as a failure and the key appears to disappear.
3. Public Endpoint display/copy intentionally strips Warren's Web auth fragment,
   but browser opening follows the same canonical URL. A direct browser load
   then cannot authenticate the WebSocket and retries forever.
4. The top Web panel repeats setup details that belong in Settings, and the
   Settings form presents both key types at once instead of making the choice
   explicit.

## Changes

- Package a release-selected gnar binary inside the Warren app when available,
  default its credential store to `~/.warren/gnar`, and keep `WARREN_GNAR_PATH`
  plus system gnar discovery backward compatible. Add an explicit config-dir
  override for operators and tests.
- Keep bootstrap keys in memory only. Save & Test persists only Edge/account
  configuration, feeds the selected key to gnar over stdin, and treats a
  successful login as the first authentication milestone. The top Web control
  starts the live tunnel afterwards; a missing token/key remains actionable.
- Keep Public Access API/display/copy endpoints credential-free. When the user
  explicitly chooses Open, append the existing Warren daemon token fragment
  only for that browser launch so the protected Web UI can authenticate. Do
  not put the fragment in API responses, clipboard contents, analytics, or
  persisted settings; document the compatibility risk.
- Add a key-kind selector (Approval Key or Invite Key) and retain a masked
  placeholder after a submitted key so the form communicates that a secret is
  configured without retaining or echoing it.
- Shorten the top Web panel copy to a single setup hint and keep Settings as
  the setup destination. Preserve disabled, loading, error/retry, keyboard,
  accessibility, and responsive states.

## Verification

- Go formatting, `cd Headless && go test ./...`, and focused process/stdin,
  credential-redaction, URL validation, lifecycle, and embedded-config tests.
- Swift formatting/build checks and the project Swift test command, including
  Public Access terminology, key-state, endpoint-open, and Web-panel tests.
- `git diff --check` plus a final review of business intrusiveness,
  interaction states, resource use, first-run defaults, and coupling.
