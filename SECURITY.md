# Security policy

## Supported versions

The latest published Warren release receives security fixes. Older releases may not receive fixes for issues that require protocol, daemon, or bundled-runtime changes.

## Reporting a vulnerability

Please use [GitHub private vulnerability reporting](https://github.com/abcdlsj/warren/security/advisories/new) when it is available. Do not post credentials, tokens, terminal output, or an exploit in a public issue.

If private reporting is unavailable, contact the repository owner through [the Warren GitHub profile](https://github.com/abcdlsj) and ask for a private reporting channel.

Include the affected version, deployment mode, reproduction steps, impact, and any proposed mitigation. Please redact secrets from logs and screenshots.

## Deployment notes

- Keep `~/.warren/token`, relay credentials, enrollment keys, and pairing URLs private.
- Do not expose the daemon's unauthenticated HTTP listener directly to the public internet.
- Public Access is an explicit owner-reachability feature, not a multi-user sharing boundary. Use TLS, a strict origin, strong secrets, and a persistent protected data volume for public relay deployments.
- Review the residual browser-history risk described in the Public Access documentation before sharing setup links.
