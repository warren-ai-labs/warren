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

Use `npm run build` and `npm run lint` before sharing a change.

## Script Command fallback

`warren-terminal.sh` stays available for users who prefer Raycast's Script
Commands directory workflow. Warren registers the
`warren://terminal?group=Inbox` URL for external launchers, and release app
bundles ship both the script and its icon, but Warren never installs either file
or changes Raycast settings on its own.

After installing Warren at `/Applications/Warren.app`, install the launcher for
the current user:

```sh
mkdir -p "$HOME/.warren"
install -m 755 \
  "/Applications/Warren.app/Contents/Resources/warren-terminal.sh" \
  "$HOME/.warren/warren-terminal.sh"
install -m 644 \
  "/Applications/Warren.app/Contents/Resources/warren-terminal.png" \
  "$HOME/.warren/warren-terminal.png"
```

Then open Raycast **Settings → Script Commands → Add Script Directory**, add
`~/.warren`, and search for **Terminal**. Raycast's **Configure Command** menu
can give it the alias `terminal` or a global hotkey.

From a source checkout, use the same two commands with
`Support/Raycast/warren-terminal.sh` and `Assets/Brand/warren-app-icon.png` as
the source paths.
