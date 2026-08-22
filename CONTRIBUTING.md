# Contributing to Warren

Thank you for helping improve Warren. Please read this guide before opening a pull request.

## Before you start

- Search existing issues and discussions before opening a new one.
- For security vulnerabilities, follow [SECURITY.md](SECURITY.md) instead of filing a public issue.
- Keep changes focused. Separate product behavior, refactors, and documentation when practical.
- Do not include credentials, private host names, terminal output, or personal data in issues, tests, screenshots, or commits.

## Development setup

Warren currently targets macOS 14 or later for the desktop client. The repository also contains the Go headless daemon, CLI, Relay Service, and Web/PWA client.

Install the repository tools with `mise`, then use the relevant checks:

```sh
mise install
mise run verify
mise run verify:web
```

When changing only one area, the narrower checks are useful:

```sh
mise run test
mise run test:headless
go test -race ./RelayService/...
npm --prefix Onboarding test
npm --prefix Onboarding run build
```

## Pull requests

Every pull request should explain:

1. What user problem the change solves.
2. Which behavior, data, or compatibility boundaries it changes.
3. What checks were run and what remains unverified.
4. Any migration, security, performance, or recovery risk and its mitigation.

Use English for user-facing text, documentation, comments, and commit messages. Prefix commit messages with a type such as `feat:`, `fix:`, `refactor:`, `test:`, or `docs:`.

Do not mark a change ready for review while loading, error, empty, retry, keyboard, accessibility, responsive, and reconnect states remain unexplained or untested where they apply.

## Scope and ownership

Warren is local-first. Host-owned resources, client projections, and transport boundaries should remain explicit. New code must not turn a cache, UI projection, or relay into a second authority for Projects, Workspaces, Sessions, or terminal output.

Contributions are accepted under the repository license. By submitting a contribution, you confirm that you have the right to do so and that it contains no confidential or third-party material that you are not allowed to publish.
