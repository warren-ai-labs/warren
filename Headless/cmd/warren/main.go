package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/config"
)

var version = "dev"
var outputJSON bool
var outputQuiet bool
var endpointName string
var endpointURL string
var endpointToken string
var configPath string

const defaultEndpointName = "local"

var relayHTTPClient = &http.Client{
	Timeout: 15 * time.Second,
	// Client Relay operations are sent to the selected local daemon. Never
	// follow a redirect to an untrusted origin where the daemon credential
	// could be replayed.
	CheckRedirect: func(_ *http.Request, _ []*http.Request) error {
		return http.ErrUseLastResponse
	},
}

func main() {
	if err := run(os.Args[1:]); err != nil {
		var usageErr *usageError
		if errors.As(err, &usageErr) {
			fmt.Fprintln(os.Stderr, "warren:", usageErr.message)
			if usageErr.text != "" {
				fmt.Fprintln(os.Stderr)
				fmt.Fprint(os.Stderr, usageErr.text)
			}
			os.Exit(2)
		}
		fmt.Fprintln(os.Stderr, "warren:", err)
		os.Exit(1)
	}
}

type usageError struct {
	message string
	text    string
}

func (e *usageError) Error() string { return e.message }

func newUsageError(message, text string) error {
	return &usageError{message: message, text: text}
}

func run(arguments []string) error {
	global := flag.NewFlagSet("warren", flag.ContinueOnError)
	global.SetOutput(io.Discard)
	global.BoolVar(&outputJSON, "json", false, "JSON output")
	global.BoolVar(&outputQuiet, "quiet", false, "only print IDs")
	global.BoolVar(&outputQuiet, "q", false, "only print IDs")
	global.StringVar(&endpointName, "endpoint", env("WARREN_ENDPOINT", ""), "endpoint name")
	global.StringVar(&endpointURL, "server", env("WARREN_SERVER", ""), "server URL")
	global.StringVar(&endpointToken, "token", env("WARREN_TOKEN", ""), "server token")
	global.StringVar(&configPath, "config", config.DefaultPath(), "config path")
	arguments = hoistGlobalFlags(arguments)
	if err := global.Parse(arguments); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			usage()
			return nil
		}
		return newUsageError(err.Error(), usageText())
	}
	args := global.Args()
	if len(args) == 0 {
		usage()
		return nil
	}
	switch args[0] {
	case "version":
		fmt.Println(version)
		return nil
	case "endpoint", "server":
		return endpointCommand(args[1:])
	case "display":
		return displayCommand(args[1:])
	case "ssh":
		return sshCommand(args[1:])
	case "agent":
		return agentCommand(args[1:])
	case "task", "project", "workspace", "worktree", "terminal-group", "group", "session", "browser", "pane":
		if args[0] == "task" && len(args) > 1 && args[1] == "workspace" {
			return taskWorkspaceCommand(args[2:])
		}
		return resourceCommand(args)
	case "headless":
		return headlessCommand(args[1:])
	case "relay":
		return relayCommand(args[1:])
	case "help", "-h", "--help":
		usage()
		return nil
	default:
		return newUsageError(fmt.Sprintf("unknown command %q; run 'warren help'", args[0]), usageText())
	}
}

func daemonToken() string {
	if value := strings.TrimSpace(os.Getenv("WARREN_TOKEN")); value != "" {
		return value
	}
	path := strings.TrimSpace(os.Getenv("WARREN_TOKEN_FILE"))
	if path == "" {
		path = filepath.Join(defaultWarrenDirectory(), "token")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(data))
}

func defaultWarrenDirectory() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ".warren"
	}
	return filepath.Join(home, ".warren")
}
