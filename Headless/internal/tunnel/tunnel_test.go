package tunnel

import (
	"log/slog"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
)

func TestParseCloudflaredURL(t *testing.T) {
	line := "2026-08-15T10:00:00Z INF +--------------------------------------------------------------------------------------------+"
	line += "\n https://warren-abc.trycloudflare.com"
	if got := parseCloudflaredURL(line); got != "https://warren-abc.trycloudflare.com" {
		t.Fatalf("parseCloudflaredURL = %q", got)
	}
	if got := parseCloudflaredURL("no url here"); got != "" {
		t.Fatalf("unexpected match %q", got)
	}
}

func TestParseTailscaleURL(t *testing.T) {
	serveJSON := []byte(`{"TCP":{"443":{"HTTPS":true}},"Web":{"host.tail3d6e0.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8789"}}}}}`)
	if got := parseTailscaleURL(serveJSON); got != "https://host.tail3d6e0.ts.net/" {
		t.Fatalf("parseTailscaleURL = %q", got)
	}
	noWeb := []byte(`{"TCP":{"443":{"HTTPS":true}}}`)
	if got := parseTailscaleURL(noWeb); got != "" {
		t.Fatalf("unexpected URL %q", got)
	}
}

func TestManagerStartAndStopCloudflaredWithFakeBinary(t *testing.T) {
	binary := writeScript(t, `#!/bin/sh
printf 'https://fake-%s.trycloudflare.com\n' "$(date +%s)"
sleep 30
`)
	manager := NewManager(slog.New(slog.NewTextHandler(os.Stderr, nil)), "http://127.0.0.1:8789", binary, "", "")
	manager.pollInterval = 10 * time.Millisecond
	manager.pollAttempts = 10

	status, err := manager.Start(KindCloudflared)
	if err != nil {
		t.Fatalf("start: %v", err)
	}
	if !status.Running {
		t.Fatal("cloudflared is not running after start")
	}

	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		current := manager.Status()[KindCloudflared]
		if current.URL != "" {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	current := manager.Status()[KindCloudflared]
	if current.URL == "" {
		t.Fatal("cloudflared URL was never discovered")
	}
	if err := manager.Stop(KindCloudflared); err != nil {
		t.Fatalf("stop: %v", err)
	}
	if _, ok := manager.Status()[KindCloudflared]; ok {
		t.Fatal("cloudflared state remained after stop")
	}
}

func TestManagerStartAndStopTailscaleWithFakeBinary(t *testing.T) {
	binary := writeScript(t, `#!/bin/sh
case "$1" in
  serve)
    if [ "$2" = "status" ]; then
      printf '%s\n' '{"Web":{"host.tail3d6e0.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8789"}}}}}'
      exit 0
    fi
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
`)
	manager := NewManager(slog.New(slog.NewTextHandler(os.Stderr, nil)), "http://127.0.0.1:8789", "", binary, "")
	manager.pollInterval = 10 * time.Millisecond
	manager.pollAttempts = 10

	status, err := manager.Start(KindTailscale)
	if err != nil {
		t.Fatalf("start tailscale: %v", err)
	}
	if status.URL != "https://host.tail3d6e0.ts.net/" {
		t.Fatalf("tailscale URL = %q", status.URL)
	}
	if err := manager.Stop(KindTailscale); err != nil {
		t.Fatalf("stop tailscale: %v", err)
	}
	if _, ok := manager.Status()[KindTailscale]; ok {
		t.Fatal("tailscale state remained after stop")
	}
}

func TestManagerStartAndStopGnarWithFakeBinary(t *testing.T) {
	binary := writeScript(t, `#!/bin/sh
printf '%s\n' '{"type":"tunnel_ready","public_url":"https://warren-host.gnar.example.com","target":"http://127.0.0.1:8789","account":null,"reserved":false}'
sleep 30
`)
	manager := NewManager(slog.New(slog.NewTextHandler(os.Stderr, nil)), "http://127.0.0.1:8789", "", "", binary)

	status, err := manager.Start(KindGnar)
	if err != nil {
		t.Fatalf("start gnar: %v", err)
	}
	if !status.Running {
		t.Fatal("gnar is not running after start")
	}
	current := manager.Status()[KindGnar]
	if current.URL != "https://warren-host.gnar.example.com" {
		t.Fatalf("gnar URL = %q, want immediate tunnel_ready URL", current.URL)
	}
	if err := manager.Stop(KindGnar); err != nil {
		t.Fatalf("stop gnar: %v", err)
	}
	if _, ok := manager.Status()[KindGnar]; ok {
		t.Fatal("gnar state remained after stop")
	}
}

func TestManagerStopAllTearsDownEveryRunningAdapter(t *testing.T) {
	cloudflared := writeScript(t, `#!/bin/sh
printf 'https://fake-%s.trycloudflare.com\n' "$(date +%s)"
sleep 60
`)
	gnar := writeScript(t, `#!/bin/sh
printf '%s\n' '{"type":"tunnel_ready","public_url":"https://warren-host.gnar.example.com","target":"http://127.0.0.1:8789","account":null,"reserved":false}'
sleep 60
`)
	manager := NewManager(slog.New(slog.NewTextHandler(os.Stderr, nil)), "http://127.0.0.1:8789", cloudflared, "", gnar)

	if _, err := manager.Start(KindCloudflared); err != nil {
		t.Fatalf("start cloudflared: %v", err)
	}
	if _, err := manager.Start(KindGnar); err != nil {
		t.Fatalf("start gnar: %v", err)
	}
	if len(manager.Status()) != 2 {
		t.Fatalf("status = %#v, want two running adapters", manager.Status())
	}

	manager.StopAll()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) && len(manager.Status()) != 0 {
		time.Sleep(10 * time.Millisecond)
	}
	if got := manager.Status(); len(got) != 0 {
		t.Fatalf("status after StopAll = %#v, want empty", got)
	}
}

func TestGnarPassesConfiguredEdge(t *testing.T) {
	argsFile := filepath.Join(t.TempDir(), "gnar-args")
	t.Setenv("GNAR_ARGS_FILE", argsFile)
	binary := writeScript(t, `#!/bin/sh
printf '%s\n' "$@" > "$GNAR_ARGS_FILE"
printf '%s\n' '{"type":"tunnel_ready","public_url":"https://warren-host.gnar.example.com","target":"http://127.0.0.1:8789","account":null,"reserved":false}'
sleep 30
`)
	manager := NewManager(slog.New(slog.NewTextHandler(os.Stderr, nil)), "http://127.0.0.1:8789", "", "", binary)
	manager.SetGnarEdge("https://edge.example.com")

	if _, err := manager.Start(KindGnar); err != nil {
		t.Fatalf("start gnar: %v", err)
	}
	defer manager.Stop(KindGnar)

	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if manager.Status()[KindGnar].URL != "" {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	data, err := os.ReadFile(argsFile)
	if err != nil {
		t.Fatalf("read gnar args: %v", err)
	}
	args := strings.Fields(string(data))
	if !slices.Contains(args, "--edge") || !slices.Contains(args, "https://edge.example.com") {
		t.Fatalf("gnar args = %q, want --edge https://edge.example.com", args)
	}
}

func TestGnarKeepsTheReportedErrorAfterExit(t *testing.T) {
	binary := writeScript(t, `#!/bin/sh
printf '%s\n' '{"type":"error","message":"no edge server is available; run gnar login first"}'
exit 1
`)
	manager := NewManager(slog.New(slog.NewTextHandler(os.Stderr, nil)), "http://127.0.0.1:8789", "", "", binary)

	status, err := manager.Start(KindGnar)
	if err != nil {
		t.Fatalf("start gnar: %v", err)
	}
	if status.Error == "" {
		t.Fatal("gnar error should be surfaced by start")
	}

	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		current := manager.Status()[KindGnar]
		if current.Error != "" && !current.Running {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	current := manager.Status()[KindGnar]
	if current.Error == "" {
		t.Fatal("gnar error was never surfaced")
	}
	if current.Running {
		t.Fatal("gnar should not be running after exit")
	}
}

func TestStartPublicAccessFeedsEnrollmentKeyOnlyToLoginStdin(t *testing.T) {
	keyFile := filepath.Join(t.TempDir(), "enrollment-key")
	argsFile := filepath.Join(t.TempDir(), "gnar-args")
	t.Setenv("GNAR_KEY_FILE", keyFile)
	t.Setenv("GNAR_ARGS_FILE", argsFile)
	binary := writeScript(t, `#!/bin/sh
if [ "$1" = "login" ]; then
  cat > "$GNAR_KEY_FILE"
  printf '%s\n' '{"type":"login_ok","account":"warren"}'
  exit 0
fi
printf '%s\n' "$@" > "$GNAR_ARGS_FILE"
printf '%s\n' '{"type":"tunnel_ready","public_url":"https://edge.example.com/warren/path","target":"http://127.0.0.1:8789"}'
sleep 30
`)
	manager := NewManager(slog.New(slog.NewTextHandler(os.Stderr, nil)), "http://127.0.0.1:8789", "", "", binary)
	status, err := manager.StartPublicAccess("https://edge.example.com", "warren", []byte("memorable-key"))
	if err != nil {
		t.Fatalf("start public access: %v", err)
	}
	defer manager.Stop(KindGnar)
	if status.URL != "https://edge.example.com/warren/path/" {
		t.Fatalf("public endpoint = %q, want path-mode trailing slash", status.URL)
	}
	key, err := os.ReadFile(keyFile)
	if err != nil {
		t.Fatalf("read login key: %v", err)
	}
	if string(key) != "memorable-key" {
		t.Fatalf("login stdin = %q, want enrollment key", key)
	}
	args, err := os.ReadFile(argsFile)
	if err != nil {
		t.Fatalf("read tunnel args: %v", err)
	}
	if strings.Contains(string(args), "memorable-key") {
		t.Fatalf("enrollment key leaked into tunnel args: %q", args)
	}
}

func TestStartPublicAccessRedactsEnrollmentKeyOnLoginFailure(t *testing.T) {
	binary := writeScript(t, `#!/bin/sh
if [ "$1" = "login" ]; then
  cat >/dev/null
  printf '%s\n' '{"type":"error","message":"invalid enrollment-key=memorable-key"}'
  exit 1
fi
`)
	manager := NewManager(slog.Default(), "http://127.0.0.1:8789", "", "", binary)
	_, err := manager.StartPublicAccess("https://edge.example.com", "warren", []byte("memorable-key"))
	if err == nil {
		t.Fatal("login failure must be returned")
	}
	if strings.Contains(err.Error(), "memorable-key") {
		t.Fatalf("login error leaked enrollment key: %v", err)
	}
}

func TestStartPublicAccessReportsTunnelFailureAndNoEndpoint(t *testing.T) {
	binary := writeScript(t, `#!/bin/sh
printf '%s\n' '{"type":"error","message":"no persisted gnar token; enrollment required"}'
sleep 1
exit 1
`)
	manager := NewManager(slog.Default(), "http://127.0.0.1:8789", "", "", binary)
	status, err := manager.StartPublicAccess("https://edge.example.com", "warren", nil)
	if err == nil {
		t.Fatal("public access must fail when gnar cannot establish a tunnel")
	}
	if status.Running || status.URL != "" || !strings.Contains(status.Error, "enrollment required") {
		t.Fatalf("failed public access status = %#v", status)
	}
	if current := manager.Status()[KindGnar]; current.Running || current.URL != "" {
		t.Fatalf("failed public access left a live endpoint: %#v", current)
	}
}

func TestStartPublicAccessRejectsGnarProcessThatExitsAfterReady(t *testing.T) {
	binary := writeScript(t, `#!/bin/sh
printf '%s\n' '{"type":"tunnel_ready","public_url":"https://edge.example.com/warren"}'
exit 0
`)
	manager := NewManager(slog.Default(), "http://127.0.0.1:8789", "", "", binary)
	status, err := manager.StartPublicAccess("https://edge.example.com", "warren", nil)
	if err == nil {
		t.Fatal("a gnar process that exits immediately must fail Public Access")
	}
	if status.Running || status.URL != "" {
		t.Fatalf("exited gnar status = %#v", status)
	}
}

func TestValidateEdgeURLRejectsCredentialBearingURLs(t *testing.T) {
	for _, value := range []string{
		"",
		"ftp://edge.example.com",
		"https://user:pass@edge.example.com",
		"https://edge.example.com?enrollment-key=secret",
		"https://edge.example.com?",
		"https://edge.example.com/#secret",
		"https://edge.example.com/#",
	} {
		if err := ValidateEdgeURL(value); err == nil {
			t.Fatalf("ValidateEdgeURL(%q) unexpectedly succeeded", value)
		}
	}
	if err := ValidateEdgeURL("https://edge.example.com/path/"); err != nil {
		t.Fatalf("valid Edge URL rejected: %v", err)
	}
}

func TestRedactionKeepsActionableNonSecretWords(t *testing.T) {
	if got := redactGnarText("gnar token required; run login"); got != "gnar token required; run login" {
		t.Fatalf("redaction changed actionable error: %q", got)
	}
}

func writeScript(t *testing.T, content string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "tunnel-adapter")
	if err := os.WriteFile(path, []byte(content), 0o700); err != nil {
		t.Fatalf("write script: %v", err)
	}
	return path
}
