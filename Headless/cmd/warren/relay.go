package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/config"
)

func relayCommand(args []string) error {
	if len(args) == 0 || isHelpArgument(args[0]) {
		fmt.Print(relayUsageText())
		return nil
	}
	flags := parseFlags(args[1:])
	if boolValue(flags, "help") || boolValue(flags, "h") {
		fmt.Print(relayUsageText())
		return nil
	}
	switch args[0] {
	case "connect", "join", "share":
	default:
		return newUsageError(fmt.Sprintf("unknown relay command: %s", args[0]), relayUsageText())
	}
	if label := missingRelayPositionals(args[0], flags); label != "" {
		return newUsageError("missing "+label, relayUsageText())
	}
	if err := validateRelayFlags(args[0], flags); err != nil {
		return err
	}
	// User-facing Relay operations are deliberately local-daemon operations.
	// The daemon owns the Host Secret and is the only Warren component that
	// speaks the Relay control-plane protocol. Relay administrator credentials
	// never need to enter this CLI.
	switch args[0] {
	case "connect", "join":
		return relayConnectCommand(flags)
	case "share":
		return relayLocalShareCommand(flags)
	}
	return newUsageError(fmt.Sprintf("unknown relay command: %s", args[0]), relayUsageText())
}

func missingRelayPositionals(command string, flags map[string]any) string {
	items := positionals(flags)
	switch command {
	case "connect", "join":
		if len(items) > 1 {
			return "a single Relay settings link"
		}
		return ""
	default:
		if len(items) > 0 {
			return ""
		}
	}
	return ""
}

func validateRelayFlags(command string, flags map[string]any) error {
	allowed := map[string]bool{"help": true, "h": true}
	switch command {
	case "connect":
		allowed["url"], allowed["relay-url"] = true, true
		allowed["key"], allowed["enrollment-key"] = true, true
		allowed["name"], allowed["settings-url"] = true, true
		allowed["share"], allowed["qr"], allowed["open"] = true, true, true
	case "join":
		allowed["url"], allowed["relay-url"] = true, true
		allowed["key"], allowed["enrollment-key"] = true, true
		allowed["name"], allowed["settings-url"] = true, true
	case "share":
		allowed["qr"], allowed["open"] = true, true
	}
	for key := range flags {
		if key == "_" || allowed[key] {
			continue
		}
		return newUsageError("unknown relay option --"+key, relayUsageText())
	}
	if command != "connect" && len(positionals(flags)) != 0 {
		return newUsageError("relay "+command+" does not accept positional arguments", relayUsageText())
	}
	return nil
}

// relayConnectCommand asks the selected local daemon to claim a Host identity
// with a short-lived Relay enrollment key. The daemon owns the long-lived Host
// credential and performs the outbound Relay request.
func relayConnectCommand(flags map[string]any) error {
	relayURL, enrollmentKey, hostName, err := relayJoinValues(flags)
	if err != nil {
		return err
	}
	daemonURL, daemonCredential, err := localDaemonValues()
	if err != nil {
		return err
	}
	if _, err := doRelayRequest(
		http.MethodPost,
		daemonURL+"/v1/relay/join",
		daemonCredential,
		map[string]any{
			"relayUrl":      relayURL,
			"enrollmentKey": enrollmentKey,
			"hostName":      hostName,
		},
	); err != nil {
		return fmt.Errorf("connect local Host to Relay: %w", err)
	}
	if boolValue(flags, "share") {
		return relayLocalShareCommand(flags)
	}
	result := map[string]any{"connected": true}
	if outputJSON {
		return printValue(result)
	}
	printKVTable([][2]string{{"RELAY", "connected"}})
	return nil
}

// relayJoinValues accepts explicit URL/key flags or a Warren settings link.
// The enrollment key is kept in memory and is never written to Warren config.
func relayJoinValues(flags map[string]any) (string, string, string, error) {
	relayURL := strings.TrimSpace(stringValue(flags, "url"))
	if relayURL == "" {
		relayURL = strings.TrimSpace(stringValue(flags, "relay-url"))
	}
	enrollmentKey := strings.TrimSpace(stringValue(flags, "key"))
	if enrollmentKey == "" {
		enrollmentKey = strings.TrimSpace(stringValue(flags, "enrollment-key"))
	}
	hostName := strings.TrimSpace(stringValue(flags, "name"))
	setupURL := strings.TrimSpace(positional(flags, 0, "Relay settings link"))
	if setupURL == "" {
		setupURL = strings.TrimSpace(stringValue(flags, "settings-url"))
	}
	if setupURL != "" {
		parsedURL, err := url.Parse(setupURL)
		if err != nil || !strings.EqualFold(parsedURL.Scheme, "warren") || !strings.EqualFold(parsedURL.Host, "settings") {
			return "", "", "", newUsageError("Relay settings link must use warren://settings", relayUsageText())
		}
		query := parsedURL.Query()
		if section := firstQueryValue(query, "section"); section != "" && !strings.EqualFold(section, "relay") {
			return "", "", "", newUsageError("--setup-url must be a Relay settings link", relayUsageText())
		}
		if relayURL == "" {
			relayURL = firstQueryValue(query, "relayUrl")
		}
		if enrollmentKey == "" {
			enrollmentKey = firstQueryValue(query, "enrollmentKey")
		}
		if hostName == "" {
			hostName = firstQueryValue(query, "hostName")
		}
	}
	if relayURL == "" {
		relayURL = strings.TrimSpace(env("WARREN_RELAY_URL", ""))
	}
	if enrollmentKey == "" {
		enrollmentKey = strings.TrimSpace(env("WARREN_RELAY_ENROLLMENT_KEY", ""))
	}
	if relayURL == "" || enrollmentKey == "" {
		return "", "", "", newUsageError("a Relay settings link or --url and --key is required", relayUsageText())
	}
	relayURL, err := normalizeRelayBase(relayURL)
	if err != nil {
		return "", "", "", newUsageError(err.Error(), relayUsageText())
	}
	return relayURL, enrollmentKey, hostName, nil
}

func firstQueryValue(query url.Values, key string) string {
	for name, values := range query {
		if strings.EqualFold(name, key) && len(values) > 0 {
			return strings.TrimSpace(values[0])
		}
	}
	return ""
}

// localDaemonValues resolves the selected Warren Host daemon. It intentionally
// rejects a Relay endpoint: a Relay access capability is not a Host Secret and
// cannot be promoted into a control-plane credential by this CLI.
func localDaemonValues() (string, string, error) {
	loaded, err := config.Load(configPath)
	if err != nil {
		return "", "", fmt.Errorf("load Warren endpoint configuration: %w", err)
	}
	value, err := resolveConfiguredEndpoint(loaded)
	if err != nil {
		return "", "", err
	}
	if strings.EqualFold(strings.TrimSpace(value.Type), "relay") {
		return "", "", errors.New("select the local Warren Host endpoint; Relay administration is owned by the Relay service")
	}
	if strings.TrimSpace(value.SSH) != "" {
		return "", "", errors.New("relay connect/share requires a local Warren Host daemon; run the command on the Host")
	}
	base := strings.TrimRight(strings.TrimSpace(value.URL), "/")
	if base == "" {
		base = "http://127.0.0.1:8789"
	}
	base, err = normalizeRelayBase(base)
	if err != nil {
		return "", "", err
	}
	credential := strings.TrimSpace(value.Token)
	if credential == "" {
		credential = daemonToken()
	}
	if credential == "" {
		return "", "", errors.New("local Warren Host token is unavailable")
	}
	return base, credential, nil
}

func relayLocalShareCommand(flags map[string]any) error {
	base, credential, err := localDaemonValues()
	if err != nil {
		return err
	}
	value, err := doRelayRequest(http.MethodPost, base+"/v1/relay/pairing", credential, nil)
	if err != nil {
		return fmt.Errorf("create Relay share from local Host: %w", err)
	}
	object, ok := value.(map[string]any)
	if !ok {
		return errors.New("local Host returned an invalid Relay share")
	}
	link := strings.TrimSpace(stringValueAny(object, "pairing_url"))
	if link == "" {
		return errors.New("local Host returned no Relay share link")
	}
	expiresIn := intValueAny(object, "expires_in")
	return printRelayPairingResult(link, expiresIn, strings.TrimSpace(stringValueAny(object, "expires_at")), flags)
}

func printRelayPairingResult(link string, expiresIn int, expiresAt string, flags map[string]any) error {
	result := map[string]any{
		"pairing_url": link,
		"expires_in":  expiresIn,
		"reusable":    true,
	}
	if expiresAt != "" {
		result["expires_at"] = expiresAt
	}
	if qr, requested := relayQRPath(flags); requested {
		if err := writeRelayQRCode(qr, link); err != nil {
			return err
		}
		result["qr_path"] = qr
	}
	if boolValue(flags, "open") {
		if err := openRelayURL(link); err != nil {
			return err
		}
	}
	if outputJSON {
		return printValue(result)
	}
	pairs := [][2]string{
		{"PAIRING URL", link},
		{"EXPIRES IN", formatRelayTTL(expiresIn)},
		{"REUSABLE", "yes (until expiry or Host re-registration)"},
	}
	if qr, requested := relayQRPath(flags); requested {
		pairs = append(pairs, [2]string{"QR", qr})
	}
	printKVTable(pairs)
	return nil
}

func stringValueAny(value map[string]any, key string) string {
	result, _ := value[key].(string)
	return result
}

func intValueAny(value map[string]any, key string) int {
	switch item := value[key].(type) {
	case float64:
		return int(item)
	case int:
		return item
	case json.Number:
		result, _ := item.Int64()
		return int(result)
	default:
		return 0
	}
}

func formatRelayTTL(seconds int) string {
	if seconds <= 0 {
		return "unknown"
	}
	duration := time.Duration(seconds) * time.Second
	if duration%(24*time.Hour) == 0 {
		return fmt.Sprintf("%dd", int(duration/(24*time.Hour)))
	}
	if duration%time.Hour == 0 {
		return fmt.Sprintf("%dh", int(duration/time.Hour))
	}
	return duration.String()
}

func relayQRPath(flags map[string]any) (string, bool) {
	raw, ok := flags["qr"]
	if !ok {
		return "", false
	}
	if value, isString := raw.(string); isString && strings.TrimSpace(value) != "" && value != "true" {
		return filepath.Clean(strings.TrimSpace(value)), true
	}
	return filepath.Clean(env("WARREN_RELAY_QR_PATH", "warren-relay-pairing.png")), true
}

func writeRelayQRCode(path, link string) error {
	encoder, err := exec.LookPath("qrencode")
	if err != nil {
		return errors.New("qrencode is required for --qr; install qrencode or omit --qr to print the pairing link")
	}
	if parent := filepath.Dir(path); parent != "." && parent != "" {
		if err := os.MkdirAll(parent, 0o700); err != nil {
			return fmt.Errorf("create QR directory: %w", err)
		}
	}
	command := exec.Command(encoder, "-o", path, "-")
	command.Stdin = strings.NewReader(link)
	command.Stdout = io.Discard
	command.Stderr = io.Discard
	if err := command.Run(); err != nil {
		return fmt.Errorf("generate QR: %w", err)
	}
	if err := os.Chmod(path, 0o600); err != nil {
		return fmt.Errorf("protect QR file: %w", err)
	}
	return nil
}

func openRelayURL(link string) error {
	commandName := "open"
	if _, err := exec.LookPath(commandName); err != nil {
		commandName = "xdg-open"
	}
	command, err := exec.LookPath(commandName)
	if err != nil {
		return errors.New("cannot open pairing link: neither open nor xdg-open is available")
	}
	commandProcess := exec.Command(command, link)
	commandProcess.Stdout = io.Discard
	commandProcess.Stderr = io.Discard
	if err := commandProcess.Start(); err != nil {
		return fmt.Errorf("open pairing link: %w", err)
	}
	return nil
}

func normalizeRelayBase(raw string) (string, error) {
	value := strings.TrimRight(strings.TrimSpace(raw), "/")
	parsed, err := url.Parse(value)
	if err != nil || parsed.Host == "" || parsed.User != nil || parsed.RawQuery != "" || parsed.Fragment != "" || parsed.Opaque != "" {
		return "", errors.New("invalid Relay URL")
	}
	if parsed.Scheme != "http" && parsed.Scheme != "https" {
		return "", errors.New("Relay URL must use http or https")
	}
	if strings.ContainsAny(parsed.Host+parsed.Path, "\r\n\x00") || strings.HasPrefix(parsed.Path, "//") {
		return "", errors.New("invalid Relay URL")
	}
	for _, segment := range strings.Split(parsed.Path, "/") {
		if segment == "." || segment == ".." {
			return "", errors.New("Relay URL path traversal is not allowed")
		}
	}
	return value, nil
}

type relayHTTPError struct {
	status int
	body   string
}

func (err *relayHTTPError) Error() string {
	if err.body == "" {
		return fmt.Sprintf("relay returned HTTP %d", err.status)
	}
	return fmt.Sprintf("relay returned HTTP %d: %s", err.status, err.body)
}

func doRelayRequest(method, endpoint, token string, body any) (any, error) {
	var reader io.Reader
	if body != nil {
		data, err := json.Marshal(body)
		if err != nil {
			return nil, err
		}
		reader = bytes.NewReader(data)
	}
	request, err := http.NewRequest(method, endpoint, reader)
	if err != nil {
		return nil, err
	}
	if token != "" {
		request.Header.Set("Authorization", "Bearer "+token)
	}
	if body != nil {
		request.Header.Set("Content-Type", "application/json")
	}
	response, err := relayHTTPClient.Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	data, readErr := io.ReadAll(io.LimitReader(response.Body, 64*1024))
	if readErr != nil {
		return nil, readErr
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return nil, &relayHTTPError{status: response.StatusCode, body: strings.TrimSpace(string(data))}
	}
	var value any
	if len(bytes.TrimSpace(data)) > 0 {
		if err := json.Unmarshal(data, &value); err != nil {
			return nil, fmt.Errorf("decode relay response: %w", err)
		}
	}
	return value, nil
}
