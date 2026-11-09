package main

import (
	"errors"
	"fmt"
	"net/http"
	"os"
	"strings"

	"github.com/mdp/qrterminal/v3"
)

func remoteUsageText() string {
	return `Usage:
  warren remote status
  warren remote enable [--relay URL]
  warren remote disable
  warren remote share [--relay URL] [--qr PATH] [--no-qr]
  warren remote rotate

Remote access reaches this Host from anywhere through a Bolthole relay that
cannot read the traffic: the phone and the Host run an end-to-end encrypted
handshake keyed by a connect code only they hold. The relay stores nothing,
so it can be the default one, your own Cloudflare Worker, or a binary you
run yourself. On the same network the phone connects directly to the Host
with the same code and switches between LAN and relay on its own.

'remote enable' connects to the relay (the build's default unless --relay is
given; --relay default drops a self-hosted relay and returns to the build's).
'remote share' prints a link and a terminal QR code that pairs any device
scanning it within 10 minutes; each device gets its own token, listed and
revocable on the Host. It also prints a Web link that pairs a browser through
the hosted Web client. It needs remote access to be on, so run 'remote enable'
first. Treat both links like passwords. 'remote rotate' replaces the connect
code and forgets every remotely paired device.
`
}

func remoteCommand(args []string) error {
	if len(args) == 0 || isHelpArgument(args[0]) {
		fmt.Print(remoteUsageText())
		return nil
	}
	flags := parseFlags(args[1:])
	if boolValue(flags, "help") || boolValue(flags, "h") {
		fmt.Print(remoteUsageText())
		return nil
	}
	allowed := map[string]bool{"help": true, "h": true}
	switch args[0] {
	case "status", "disable", "rotate":
	case "enable":
		allowed["relay"] = true
	case "share":
		allowed["relay"], allowed["qr"], allowed["no-qr"] = true, true, true
	default:
		return newUsageError(fmt.Sprintf("unknown remote command: %s", args[0]), remoteUsageText())
	}
	for key := range flags {
		if key != "_" && !allowed[key] {
			return newUsageError("unknown remote option --"+key, remoteUsageText())
		}
	}
	if len(positionals(flags)) != 0 {
		return newUsageError("remote "+args[0]+" does not accept positional arguments", remoteUsageText())
	}
	base, credential, err := localDaemonValues()
	if err != nil {
		return err
	}
	var body any
	if relay := strings.TrimSpace(stringValue(flags, "relay")); relay != "" {
		body = map[string]string{"relayUrl": relay}
	}
	method, path := http.MethodPost, "/v1/remote/"+args[0]
	if args[0] == "status" {
		method, path = http.MethodGet, "/v1/remote"
	}
	value, err := doRelayRequest(method, base+path, credential, body)
	if err != nil {
		return fmt.Errorf("remote %s: %w", args[0], err)
	}
	object, ok := value.(map[string]any)
	if !ok {
		return errors.New("local Host returned an invalid response")
	}
	if args[0] == "share" {
		return printRemoteShare(object, flags)
	}
	if outputJSON {
		return printValue(object)
	}
	relay := displayedRemoteRelay(object)
	pairs := [][2]string{
		{"ENABLED", fmt.Sprint(object["enabled"] == true)},
		{"STATE", stringValueAny(object, "state")},
		{"RELAY", relay},
		{"RELAY SOURCE", stringValueAny(object, "relaySource")},
		{"REMOTE DEVICES", fmt.Sprint(intValueAny(object, "devices"))},
	}
	if lastError := stringValueAny(object, "lastError"); lastError != "" {
		pairs = append(pairs, [2]string{"LAST ERROR", lastError})
	}
	printKVTable(pairs)
	return nil
}

func printRemoteShare(object map[string]any, flags map[string]any) error {
	link := strings.TrimSpace(stringValueAny(object, "link"))
	if link == "" {
		return errors.New("local Host returned no share link")
	}
	expiresIn := intValueAny(object, "expiresIn")
	if path := strings.TrimSpace(stringValue(flags, "qr")); path != "" && path != "true" {
		if err := writeRelayQRCode(path, link); err != nil {
			return err
		}
		object["qrPath"] = path
	}
	if outputJSON {
		return printValue(object)
	}
	if !boolValue(flags, "no-qr") {
		qrterminal.GenerateHalfBlock(link, qrterminal.L, os.Stdout)
	}
	pairs := [][2]string{
		{"LINK", link},
	}
	if webLink := strings.TrimSpace(stringValueAny(object, "webLink")); webLink != "" {
		pairs = append(pairs, [2]string{"WEB LINK", webLink})
	}
	pairs = append(pairs, [][2]string{
		{"RELAY", displayedRemoteRelay(object)},
		{"PAIRS DEVICES FOR", formatRelayTTL(expiresIn)},
	}...)
	if path, ok := object["qrPath"].(string); ok {
		pairs = append(pairs, [2]string{"QR", path})
	}
	printKVTable(pairs)
	return nil
}

// displayedRemoteRelay names the relay for a table: a self-hosted relay by its
// URL, the build's official relay by name only, so its address does not end up
// in pasted terminal output. `--json` still carries every field.
func displayedRemoteRelay(object map[string]any) string {
	relay := stringValueAny(object, "relayURL")
	if relay == "" {
		relay = stringValueAny(object, "configuredRelayURL")
	}
	official := stringValueAny(object, "defaultRelayURL")
	if relay == "" || stringValueAny(object, "relaySource") == "default" || (official != "" && relay == official) {
		return "official"
	}
	return relay
}
