# Warren Raycast Extension

This extension adds a configurable **Terminal** command to Raycast. Search for
`terminal` in Raycast to run it. It opens Warren's `warren://terminal` URL and
resolves the configured group by its current name or ID, so the extension does
not maintain a second copy of Warren's resource database.

The extension package is MIT-licensed for Raycast distribution; the enclosing
Warren repository remains Apache-2.0 licensed.

The command defaults to the `Inbox` group. Change **Terminal Group** in the
command preferences when another group should be opened, and change **Warren
Application** only when the app is registered under a different name or bundle
ID.

## Local development

From this directory:

```sh
npm install
npm run dev
```

Use `npm run build` and `npm run lint` before sharing a change. The existing
`warren-terminal.sh` Script Command remains available for users who prefer
Raycast's Script Commands directory workflow.
