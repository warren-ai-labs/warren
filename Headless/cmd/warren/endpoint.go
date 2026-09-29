package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/client"
	"github.com/abcdlsj/warren/Headless/internal/config"
	"github.com/abcdlsj/warren/Headless/internal/sshclient"
)

func connect() (context.Context, *client.Client, error) {
	dialContext, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	url, token := endpointURL, endpointToken
	endpointType := "daemon"
	hostID := ""
	var tunnel *sshclient.Tunnel
	if url == "" {
		settings, err := config.Load(configPath)
		if err != nil {
			return nil, nil, err
		}
		value, err := resolveConfiguredEndpoint(settings)
		if err != nil {
			return nil, nil, err
		}
		url, token = value.URL, value.Token
		endpointType = strings.ToLower(strings.TrimSpace(value.Type))
		if endpointType == "" {
			endpointType = "daemon"
		}
		hostID = strings.TrimSpace(value.HostID)
		if strings.TrimSpace(value.SSH) != "" {
			var ready sshclient.Ready
			remoteAddress := value.SSHRemote
			if strings.TrimSpace(remoteAddress) == "" {
				remoteAddress = "127.0.0.1:8789"
			}
			tunnel, ready, err = sshclient.Start(dialContext, sshclient.Options{
				Target:        value.SSH,
				RemoteAddress: remoteAddress,
				LocalAddress:  "127.0.0.1:0",
			})
			if err != nil {
				return nil, nil, fmt.Errorf("start SSH endpoint %q: %w", value.SSH, err)
			}
			url, token = ready.URL, ready.Token
		}
	}
	if token == "" {
		if tunnel != nil {
			_ = tunnel.Close()
		}
		return nil, nil, errors.New("endpoint token is required")
	}
	var value *client.Client
	var err error
	if endpointType == "relay" {
		if hostID == "" {
			return nil, nil, errors.New("Relay endpoint host ID is required")
		}
		value, err = client.DialRelay(dialContext, url, hostID, token)
	} else {
		value, err = client.Dial(dialContext, url, token)
	}
	if err != nil {
		if tunnel != nil {
			_ = tunnel.Close()
		}
		return nil, nil, err
	}
	if tunnel != nil {
		value.SetCloseHook(func() { _ = tunnel.Close() })
	}
	return context.Background(), value, nil
}

// resolveConfiguredEndpoint keeps the Desktop's synthetic "local" catalog
// selection usable by the CLI even when an older/fresh config has no explicit
// local row. Installed builds normally persist this row; the fallback reads
// the daemon-owned token without copying it into endpoint metadata.
func resolveConfiguredEndpoint(settings config.Config) (config.Endpoint, error) {
	name := endpointName
	if name == "" {
		name = settings.Current
		if name == "" {
			if len(settings.Endpoints) > 1 {
				return config.Endpoint{}, errors.New("multiple endpoints configured; run 'warren endpoint list', then retry with --endpoint NAME")
			}
			if _, ok := settings.Endpoints[defaultEndpointName]; ok {
				name = defaultEndpointName
			} else {
				// A fresh checkout has no catalog row yet, but the local daemon
				// still owns a token file. Treat that daemon as the implicit
				// endpoint instead of requiring a one-time endpoint setup command.
				name = defaultEndpointName
			}
		}
	}
	if name == defaultEndpointName {
		if value, ok := settings.Endpoints[defaultEndpointName]; ok &&
			(strings.TrimSpace(value.SSH) != "" || strings.TrimSpace(value.Token) != "") {
			return value, nil
		}
		tokenPath := strings.TrimSpace(os.Getenv("WARREN_TOKEN_FILE"))
		if tokenPath == "" {
			home, _ := os.UserHomeDir()
			tokenPath = filepath.Join(home, ".warren", "token")
		}
		data, err := os.ReadFile(tokenPath)
		if err != nil {
			return config.Endpoint{}, fmt.Errorf("read local endpoint token %s: %w", tokenPath, err)
		}
		token := strings.TrimSpace(string(data))
		if token == "" {
			return config.Endpoint{}, fmt.Errorf("local endpoint token is empty: %s", tokenPath)
		}
		return config.Endpoint{Name: "local", URL: "http://127.0.0.1:8789", Token: token}, nil
	}
	value, err := settings.Resolve(name)
	if err != nil {
		return config.Endpoint{}, fmt.Errorf("%w; add one with 'warren endpoint add' or pass --server and --token", err)
	}
	return value, nil
}

func resolveEndpoint(settings config.Config, name string) (config.Endpoint, error) {
	name = strings.TrimSpace(name)
	if name == "" {
		if len(settings.Endpoints) > 1 {
			return config.Endpoint{}, errors.New("multiple endpoints configured; run 'warren endpoint list', then retry with --endpoint NAME")
		}
		if _, ok := settings.Endpoints[defaultEndpointName]; ok {
			name = defaultEndpointName
		}
	}
	value, err := settings.Resolve(name)
	if err != nil {
		return config.Endpoint{}, fmt.Errorf("%w; add one with 'warren endpoint add' or pass --server and --token", err)
	}
	return value, nil
}

func endpointCommand(args []string) error {
	settings, err := config.Load(configPath)
	if err != nil {
		return err
	}
	if len(args) == 0 || args[0] == "list" {
		if outputJSON {
			return printValue(settings)
		}
		rows := make([][]string, 0, len(settings.Endpoints))
		for _, name := range settings.Names() {
			value := settings.Endpoints[name]
			marker := ""
			if name == settings.Current {
				marker = "*"
			}
			endpointType := strings.TrimSpace(value.Type)
			if endpointType == "" {
				endpointType = "daemon"
			}
			rows = append(rows, []string{marker, name, endpointType, value.URL, displayValue(value.HostID), displayValue(value.SSH)})
		}
		printTable([]string{"CURRENT", "NAME", "TYPE", "URL", "HOST ID", "SSH"}, rows...)
		return nil
	}
	if isHelpArgument(args[0]) || (len(args) >= 2 && isHelpArgument(args[1])) {
		fmt.Print(endpointUsageText())
		return nil
	}
	switch args[0] {
	case "add":
		flags := parseFlags(args[1:])
		if boolValue(flags, "help") || boolValue(flags, "h") {
			fmt.Print(endpointUsageText())
			return nil
		}
		if label := missingPositional(flags, []string{"ENDPOINT_NAME"}); label != "" {
			return newUsageError("missing "+label, endpointUsageText())
		}
		name := positional(flags, 0, "endpoint name")
		url := stringValue(flags, "url")
		token := stringValue(flags, "token")
		sshTarget := strings.TrimSpace(stringValue(flags, "ssh"))
		if sshTarget != "" && name == "local" {
			return newUsageError("local is reserved for the local daemon; choose another SSH endpoint name", endpointUsageText())
		}
		if sshTarget != "" && (url != "" || token != "") {
			return newUsageError("--ssh cannot be combined with --url or --token", endpointUsageText())
		}
		if sshTarget == "" && (url == "" || token == "") {
			return newUsageError("--url and --token are required", endpointUsageText())
		}
		endpointType := strings.ToLower(strings.TrimSpace(stringValueDefault(flags, "type", "daemon")))
		if endpointType == "" {
			endpointType = "daemon"
		}
		if endpointType != "daemon" && endpointType != "relay" {
			return newUsageError("--type must be daemon or relay", endpointUsageText())
		}
		if endpointType == "relay" && sshTarget != "" {
			return newUsageError("--type relay cannot be combined with --ssh", endpointUsageText())
		}
		if endpointType == "relay" && strings.TrimSpace(stringValueDefault(flags, "host-id", stringValue(flags, "host"))) == "" {
			return newUsageError("--host-id is required for relay endpoints", endpointUsageText())
		}
		if err := config.Update(configPath, func(settings *config.Config) error {
			// SSH endpoints keep only durable connection metadata. The helper
			// obtains a fresh loopback URL/token for each command invocation.
			if sshTarget != "" {
				url, token = "", ""
			}
			settings.Endpoints[name] = config.Endpoint{
				Name: name, URL: url, Token: token, SSH: sshTarget,
				SSHRemote: stringValue(flags, "ssh-remote"),
				Type:      endpointType,
				HostID:    strings.TrimSpace(stringValueDefault(flags, "host-id", stringValue(flags, "host"))),
				RouteID:   strings.TrimSpace(stringValue(flags, "route-id")),
			}
			if settings.Current == "" || boolValue(flags, "use") {
				settings.Current = name
			}
			if settings.Display != nil {
				if err := normalizeConfiguredDisplay(settings); err != nil {
					return err
				}
			}
			return nil
		}); err != nil {
			return err
		}
		return printValue(map[string]any{"added": true, "name": name})
	case "use":
		if len(args) < 2 {
			return newUsageError("missing ENDPOINT_NAME", endpointUsageText())
		}
		if err := config.Update(configPath, func(settings *config.Config) error {
			if args[1] != "local" {
				if _, ok := settings.Endpoints[args[1]]; !ok {
					return fmt.Errorf("endpoint not found: %s", args[1])
				}
			}
			settings.Current = args[1]
			if settings.Display != nil {
				if err := normalizeConfiguredDisplay(settings); err != nil {
					return err
				}
			}
			return nil
		}); err != nil {
			return err
		}
		return printValue(map[string]any{"current": args[1]})
	case "remove":
		if len(args) < 2 {
			return newUsageError("missing ENDPOINT_NAME", endpointUsageText())
		}
		if err := config.Update(configPath, func(settings *config.Config) error {
			if args[1] == "" {
				return newUsageError("missing ENDPOINT_NAME", endpointUsageText())
			}
			if args[1] != defaultEndpointName {
				if _, exists := settings.Endpoints[args[1]]; !exists {
					return fmt.Errorf("endpoint not found: %s", args[1])
				}
			}
			// Validate the old set before deleting its endpoint. Calling
			// EffectiveDisplay after deletion would (incorrectly) reject the
			// endpoint that this atomic operation is intentionally removing.
			var aliases []string
			if settings.Display != nil {
				var err error
				aliases, err = settings.EffectiveDisplay()
				if err != nil {
					return err
				}
				if index := indexOfString(aliases, args[1]); index >= 0 {
					aliases = append(aliases[:index], aliases[index+1:]...)
				}
				if len(aliases) == 0 {
					settings.Display = nil
				} else {
					settings.Display = &config.DisplayConfig{
						Version:   config.DisplayConfigVersion,
						Endpoints: aliases,
						Names:     cloneDisplayNames(settings.Display),
					}
				}
				if settings.Display != nil {
					delete(settings.Display.Names, args[1])
				}
			}
			delete(settings.Endpoints, args[1])
			if settings.Current == args[1] {
				settings.Current = firstRemainingEndpoint(settings.Endpoints)
			}
			if settings.Display != nil {
				return settings.NormalizeDisplay()
			}
			return nil
		}); err != nil {
			return err
		}
		return printValue(map[string]any{"removed": true, "name": args[1]})
	case "current":
		value, err := resolveConfiguredEndpoint(settings)
		if err != nil {
			return err
		}
		return printValue(value)
	default:
		return newUsageError(fmt.Sprintf("unknown endpoint command: %s", args[0]), endpointUsageText())
	}
}
