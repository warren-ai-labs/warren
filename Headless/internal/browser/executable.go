package browser

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

var (
	errNoExecutable = errors.New("browser: no Chromium executable found")
	errLaunchFailed = errors.New("browser: chromium failed to start")
)

// executableCandidates returns the paths and names searched, in order (RFC 0022
// §5). An explicit override wins, then PATH, then the platform's well-known
// install locations.
func executableCandidates() []string {
	candidates := make([]string, 0, 16)
	if explicit := strings.TrimSpace(os.Getenv("WARREN_BROWSER_PATH")); explicit != "" {
		candidates = append(candidates, explicit)
	}
	if explicit := strings.TrimSpace(os.Getenv("WARREN_BROWSER_EXECUTABLE")); explicit != "" {
		candidates = append(candidates, explicit)
	}
	candidates = append(candidates, "Google Chrome", "Chromium", "Google Chrome for Testing")
	switch runtime.GOOS {
	case "darwin":
		candidates = append(candidates,
			"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
			"/Applications/Chromium.app/Contents/MacOS/Chromium",
			"/Applications/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing",
			"/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
			"/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
			// Chrome for Testing unpacks into ~/chrome-for-testing by default.
			filepath.Join(homeDir(), "chrome-for-testing", "chrome-mac-arm64", "Google Chrome for Testing.app", "Contents", "MacOS", "Google Chrome for Testing"),
			filepath.Join(homeDir(), "chrome-for-testing", "chrome-mac-x64", "Google Chrome for Testing.app", "Contents", "MacOS", "Google Chrome for Testing"),
		)
	case "linux":
		candidates = append(candidates,
			"google-chrome", "google-chrome-stable", "chromium", "chromium-browser",
			"/usr/bin/google-chrome", "/usr/bin/chromium", "/usr/bin/chromium-browser",
			"/opt/google/chrome/chrome",
		)
	case "windows":
		candidates = append(candidates, "chrome.exe", "msedge.exe", "brave.exe")
	}
	return candidates
}

func homeDir() string {
	dir, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return dir
}

// resolveExecutable returns the first candidate that exists and is executable.
// The error carries the full search list, because "no browser found" without a
// list of where we looked is not an actionable message.
func resolveExecutable() (string, error) {
	tried := executableCandidates()
	for _, candidate := range tried {
		if resolved, ok := tryExecutable(candidate); ok {
			return resolved, nil
		}
	}
	return "", fmt.Errorf("%w (searched: %s)", errNoExecutable, strings.Join(tried, ", "))
}

// tryExecutable resolves one candidate. An absolute path is checked directly; a
// bare name is resolved through PATH so a wrapper script works too.
func tryExecutable(candidate string) (string, bool) {
	if candidate == "" {
		return "", false
	}
	if strings.ContainsRune(candidate, os.PathSeparator) {
		info, err := os.Stat(candidate)
		if err != nil || info.IsDir() {
			return "", false
		}
		return candidate, true
	}
	resolved, err := exec.LookPath(candidate)
	if err != nil {
		return "", false
	}
	return resolved, true
}

// chromiumFlags are the launch arguments for a managed instance (RFC 0022 §5).
//
// Two of them are the reason the embedded browser works at all:
// --disable-site-isolation-processes keeps the outer frame in one renderer so
// Page.startScreencast can capture it, and --disable-features=IsolateOrigins is
// the same concession for origin isolation. Both are safe here because the
// profile is per-Session and is never a browsing profile.
func chromiumFlags(userDataDir string, port int, headless bool) []string {
	flags := []string{
		// Loopback CDP on a private port. --remote-allow-origins is deliberately
		// NOT set: Warren speaks CDP from the Host, not from a web page, and
		// enabling it would let any page reach the debugger.
		fmt.Sprintf("--remote-debugging-port=%d", port),
		// Required for screencast to capture the outer frame.
		"--disable-site-isolation-processes",
		"--disable-features=IsolateOrigins,IsolateOriginsForSandboxedDocuments",
		// A first-run bubble, a crash-report prompt, or a profile picker would
		// each be a window the agent did not ask for.
		"--no-first-run",
		"--no-default-browser-check",
		"--disable-session-crashed-bubble",
		"--disable-infobars",
		"--disable-component-update-prompt",
		"--noerrdialogs",
		"--disable-breakpad",
		"--disable-crash-reporter",
		// Keeps an offscreen or occluded window from being throttled, which
		// would freeze both the screencast and timers the page relies on.
		"--disable-backgrounding-occluded-windows",
		"--disable-renderer-backgrounding",
		"--disable-background-timer-throttling",
		// Prompts the agent cannot answer must not appear at all.
		"--disable-features=Translate,MediaRouter,DialMediaRouteProvider",
		// Deterministic rendering for screenshots.
		"--force-color-profile=srgb",
		"--hide-scrollbars",
		"--mute-audio",
		// Per-Session isolation: a browser Session scoped to one Workspace must
		// never see another Workspace's cookies or storage.
		fmt.Sprintf("--user-data-dir=%s", userDataDir),
		"--disable-extensions",
		"--disable-sync",
		"--disable-default-apps",
	}
	if headless {
		// headless=new is the mode that supports screencast; the legacy headless
		// mode cannot capture frames.
		flags = append(flags, "--headless=new", "--disable-gpu")
	}
	return flags
}

// debuggingPort picks a free loopback port.
func debuggingPort() (int, error) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, fmt.Errorf("allocate debugging port: %w", err)
	}
	defer listener.Close()
	return listener.Addr().(*net.TCPAddr).Port, nil
}

// launchedProcess is one managed Chromium process plus its debugging endpoint.
type launchedProcess struct {
	cmd        *exec.Cmd
	executable string
	port       int
	wsURL      string
}

// launch starts Chromium with the given profile and waits until its CDP
// endpoint answers. The wait is bounded: a Chrome that never opens its port has
// failed, and polling forever would hold a Session in "starting" forever.
func launch(ctx context.Context, executable, userDataDir string, headless bool) (*launchedProcess, error) {
	port, err := debuggingPort()
	if err != nil {
		return nil, err
	}
	cmd := exec.Command(executable, chromiumFlags(userDataDir, port, headless)...)
	cmd.Dir = userDataDir
	cmd.Env = chromiumEnvironment()
	// Chromium is chatty on stderr even when healthy. Discarding it keeps the
	// Host log readable; the CDP endpoint is the health signal.
	cmd.Stdout = nil
	cmd.Stderr = nil
	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("%w: %v", errLaunchFailed, err)
	}

	wsURL, err := waitForDebugger(ctx, port)
	if err != nil {
		terminate(cmd)
		return nil, fmt.Errorf("%w: %v", errLaunchFailed, err)
	}
	return &launchedProcess{cmd: cmd, executable: executable, port: port, wsURL: wsURL}, nil
}

// chromiumEnvironment returns the environment for a managed Chromium. When a
// profile home is configured, HOME and the XDG roots are redirected into it so
// Chromium cannot pick up personal state through a default path.
func chromiumEnvironment() []string {
	dir := strings.TrimSpace(os.Getenv("WARREN_BROWSER_PROFILE_HOME"))
	if dir == "" {
		return os.Environ()
	}
	return append(os.Environ(),
		"HOME="+dir,
		"XDG_CONFIG_HOME="+filepath.Join(dir, ".config"),
		"XDG_CACHE_HOME="+filepath.Join(dir, ".cache"),
		"XDG_DATA_HOME="+filepath.Join(dir, ".local", "share"),
	)
}

// waitForDebugger polls /json/version until Chromium publishes its
// webSocketDebuggerUrl, then returns it.
func waitForDebugger(ctx context.Context, port int) (string, error) {
	endpoint := fmt.Sprintf("http://127.0.0.1:%d/json/version", port)
	deadline := time.Now().Add(30 * time.Second)
	client := &http.Client{Timeout: 2 * time.Second}
	var lastErr error
	for {
		body, err := getJSON(ctx, client, endpoint)
		if err == nil {
			var version struct {
				WebSocketDebuggerURL string `json:"webSocketDebuggerUrl"`
			}
			if json.Unmarshal(body, &version) == nil && version.WebSocketDebuggerURL != "" {
				return version.WebSocketDebuggerURL, nil
			}
			err = errors.New("no webSocketDebuggerUrl in /json/version")
		}
		lastErr = err
		if ctx.Err() != nil {
			return "", ctx.Err()
		}
		if time.Now().After(deadline) {
			return "", fmt.Errorf("debugger endpoint %s never answered: %v", endpoint, lastErr)
		}
		select {
		case <-time.After(150 * time.Millisecond):
		case <-ctx.Done():
			return "", ctx.Err()
		}
	}
}

func getJSON(ctx context.Context, client *http.Client, endpoint string) ([]byte, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return nil, err
	}
	response, err := client.Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("GET %s: status %d", endpoint, response.StatusCode)
	}
	return io.ReadAll(response.Body)
}

// terminate stops a Chromium process and waits for it to exit.
func terminate(cmd *exec.Cmd) {
	if cmd == nil || cmd.Process == nil {
		return
	}
	if err := cmd.Process.Signal(os.Interrupt); err != nil {
		_ = cmd.Process.Kill()
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		_ = cmd.Process.Kill()
		<-done
	}
}

// debuggerPathURL rewrites the debugger URL's path, which is how a browser-level
// endpoint becomes a per-target one.
func debuggerPathURL(wsURL, path string) string {
	parsed, err := url.Parse(wsURL)
	if err != nil {
		return wsURL
	}
	parsed.Path = path
	parsed.RawQuery = ""
	return parsed.String()
}
