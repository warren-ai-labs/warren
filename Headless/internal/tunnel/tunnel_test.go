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

func TestGnarStderrIsDrainedWhileStdoutStaysOpen(t *testing.T) {
	binary := writeScript(t, `#!/bin/sh
printf '%s\n' '{"type":"error","message":"no persisted gnar token; enrollment required"}' >&2
i=0
while [ "$i" -lt 20000 ]; do
  printf 'gnar diagnostic line %s\n' "$i" >&2
  i=$((i + 1))
done
sleep 30
`)
	manager := NewManager(slog.New(slog.NewTextHandler(os.Stderr, nil)), "http://127.0.0.1:8789", "", "", binary)
	manager.pollInterval = 10 * time.Millisecond
	manager.pollAttempts = 20

	started := time.Now()
	status, err := manager.Start(KindGnar)
	if err != nil {
		t.Fatalf("start should return the child error status without hanging: %v", err)
	}
	if status.Error == "" || status.Running || status.URL != "" {
		t.Fatalf("stderr error status = %#v", status)
	}
	if elapsed := time.Since(started); elapsed > 2*time.Second {
		t.Fatalf("stderr drain took too long: %v", elapsed)
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
	nameIndex := slices.Index(args, "--name")
	if nameIndex < 0 || nameIndex+1 >= len(args) {
		t.Fatalf("gnar args = %q, want a --name endpoint", args)
	}
	name := args[nameIndex+1]
	if len(name) != len("warren-")+4 || !strings.HasPrefix(name, "warren-") {
		t.Fatalf("gnar endpoint name = %q, want warren- plus four uppercase letters", name)
	}
	for _, character := range name[len("warren-"):] {
		if character < 'A' || character > 'Z' {
			t.Fatalf("gnar endpoint name = %q, suffix contains non-uppercase letter", name)
		}
	}
}

func TestGnarEdgeOverrideFallsBackToReleaseDefault(t *testing.T) {
	manager := NewManager(nil, "http://127.0.0.1:8789", "", "", "/missing/gnar")
	manager.SetGnarDefaultEdge("https://release.example.com")
	manager.SetGnarEdge("https://custom.example.com")
	manager.SetGnarEdgeOverride("")
	if got := manager.GnarEdge(); got != "https://release.example.com" {
		t.Fatalf("effective Edge after clearing override = %q", got)
	}
	if got := manager.GnarDefaultEdge(); got != "https://release.example.com" {
		t.Fatalf("release default Edge = %q", got)
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

func TestGnarRetriesWithAllocatedNameWhenReservationConflicts(t *testing.T) {
	argsPath := filepath.Join(t.TempDir(), "gnar-args")
	t.Setenv("GNAR_ARGS_FILE", argsPath)
	binary := writeScript(t, `#!/bin/sh
named=0
for argument in "$@"; do
  if [ "$argument" = "--name" ]; then named=1; fi
done
attempts=0
if [ -f "$GNAR_ARGS_FILE" ]; then attempts=$(wc -l < "$GNAR_ARGS_FILE"); fi
if [ "$named" = "1" ] && [ "$attempts" = "0" ]; then
  printf '%s\n' "named" >> "$GNAR_ARGS_FILE"
  printf '%s\n' '{"type":"error","message":"edge connection failed: the name warren-host is reserved by abcdlsj; choose another --name"}'
  exit 1
fi
if [ "$named" = "1" ]; then
  printf '%s\n' "fresh-named" >> "$GNAR_ARGS_FILE"
else
  printf '%s\n' "unexpected-unnamed" >> "$GNAR_ARGS_FILE"
fi
printf '%s\n' '{"type":"tunnel_ready","public_url":"https://edge.example.com/allocated"}'
sleep 30
`)
	manager := NewManager(slog.Default(), "http://127.0.0.1:19789", "", "", binary)
	manager.pollInterval = 10 * time.Millisecond
	manager.pollAttempts = 100
	status, err := manager.StartPublicAccess("https://edge.example.com", "warren", nil)
	if err != nil {
		t.Fatalf("start public access should recover from a reserved name: %v", err)
	}
	defer manager.Stop(KindGnar)
	if !status.Running || status.URL != "https://edge.example.com/allocated/" {
		t.Fatalf("recovered public access status = %#v", status)
	}
	args, err := os.ReadFile(argsPath)
	if err != nil {
		t.Fatalf("read gnar invocation log: %v", err)
	}
	if got := strings.Fields(string(args)); !slices.Equal(got, []string{"named", "fresh-named"}) {
		t.Fatalf("gnar invocations = %#v, want named then fresh named", got)
	}
	if current := manager.Status()[KindGnar]; current.Error != "" || !current.Running {
		t.Fatalf("manager retained the failed named process: %#v", current)
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

func TestGnarUsesDedicatedConfigDirForLoginAndTunnel(t *testing.T) {
	loginConfigPath := filepath.Join(t.TempDir(), "login-config-dir")
	tunnelConfigPath := filepath.Join(t.TempDir(), "tunnel-config-dir")
	configDir := filepath.Join(t.TempDir(), "warren", "gnar")
	t.Setenv("GNAR_CONFIG_DIR", "system-gnar-config")
	t.Setenv("GNAR_LOGIN_CONFIG_FILE", loginConfigPath)
	t.Setenv("GNAR_TUNNEL_CONFIG_FILE", tunnelConfigPath)
	binary := writeScript(t, `#!/bin/sh
if [ "$1" = "login" ]; then
  printf '%s' "$GNAR_CONFIG_DIR" > "$GNAR_LOGIN_CONFIG_FILE"
  cat >/dev/null
  printf '%s\n' '{"type":"login_ok"}'
  exit 0
fi
printf '%s' "$GNAR_CONFIG_DIR" > "$GNAR_TUNNEL_CONFIG_FILE"
printf '%s\n' '{"type":"tunnel_ready","public_url":"https://edge.example.com/warren"}'
sleep 30
`)
	manager := NewManager(slog.Default(), "http://127.0.0.1:8789", "", "", binary)
	manager.SetGnarConfigDir(configDir)
	status, err := manager.StartPublicAccess("https://edge.example.com", "warren", []byte("approval-key"))
	if err != nil {
		t.Fatalf("start public access: %v", err)
	}
	defer manager.Stop(KindGnar)
	if !status.Running || status.URL == "" {
		t.Fatalf("public access status = %#v", status)
	}
	for path, label := range map[string]string{
		loginConfigPath:  "login",
		tunnelConfigPath: "tunnel",
	} {
		value, readErr := os.ReadFile(path)
		if readErr != nil {
			t.Fatalf("read %s config directory: %v", label, readErr)
		}
		if string(value) != configDir {
			t.Fatalf("%s GNAR_CONFIG_DIR = %q, want %q", label, value, configDir)
		}
	}
}

func TestRepeatedPublicAccessTestDoesNotRepeatLogin(t *testing.T) {
	loginCountPath := filepath.Join(t.TempDir(), "login-count")
	t.Setenv("GNAR_LOGIN_COUNT", loginCountPath)
	binary := writeScript(t, `#!/bin/sh
if [ "$1" = "login" ]; then
  count=0
  if [ -f "$GNAR_LOGIN_COUNT" ]; then count=$(cat "$GNAR_LOGIN_COUNT"); fi
  count=$((count + 1))
  printf '%s' "$count" > "$GNAR_LOGIN_COUNT"
  cat >/dev/null
  printf '%s\n' '{"type":"login_ok"}'
  exit 0
fi
printf '%s\n' '{"type":"tunnel_ready","public_url":"https://edge.example.com/repeat"}'
sleep 30
`)
	manager := NewManager(slog.Default(), "http://127.0.0.1:8789", "", "", binary)

	if _, err := manager.TestPublicAccess(
		"https://edge.example.com",
		"warren",
		LoginKeyApproval,
		[]byte("approval-secret"),
	); err != nil {
		t.Fatalf("first Public Access test: %v", err)
	}
	if _, err := manager.TestPublicAccess(
		"https://edge.example.com",
		"warren",
		LoginKeyApproval,
		[]byte("approval-secret"),
	); err != nil {
		t.Fatalf("repeated Public Access test: %v", err)
	}
	count, err := os.ReadFile(loginCountPath)
	if err != nil {
		t.Fatalf("read login count: %v", err)
	}
	if string(count) != "1" {
		t.Fatalf("repeated test invoked gnar login %q times", count)
	}
}

func TestResetGnarLocalSetupRemovesOnlyOwnedCredentialStore(t *testing.T) {
	directory := filepath.Join(t.TempDir(), "warren", "gnar")
	if err := os.MkdirAll(directory, 0o700); err != nil {
		t.Fatal(err)
	}
	credential := filepath.Join(directory, "account.json")
	if err := os.WriteFile(credential, []byte("gnar-owned-token"), 0o600); err != nil {
		t.Fatal(err)
	}
	manager := NewManager(slog.Default(), "http://127.0.0.1:8789", "", "", "/missing/gnar")
	manager.SetGnarConfigDir(directory)
	manager.SetGnarConfigDirOwned(true)
	manager.markGnarAuthenticated("https://edge.example.com", "warren")

	if err := manager.ResetGnarLocalSetup(); err != nil {
		t.Fatalf("reset local setup: %v", err)
	}
	if _, err := os.Stat(directory); !os.IsNotExist(err) {
		t.Fatalf("owned credential directory still exists: %v", err)
	}
	if manager.GnarAuthenticated() {
		t.Fatal("reset left the in-memory authentication hint set")
	}
}

func TestResetGnarLocalSetupLeavesExplicitCredentialStore(t *testing.T) {
	directory := filepath.Join(t.TempDir(), "system-gnar")
	if err := os.MkdirAll(directory, 0o700); err != nil {
		t.Fatal(err)
	}
	credential := filepath.Join(directory, "account.json")
	if err := os.WriteFile(credential, []byte("system-token"), 0o600); err != nil {
		t.Fatal(err)
	}
	manager := NewManager(slog.Default(), "http://127.0.0.1:8789", "", "", "/missing/gnar")
	manager.SetGnarConfigDir(directory)

	if err := manager.ResetGnarLocalSetup(); err != nil {
		t.Fatalf("reset explicit setup: %v", err)
	}
	if _, err := os.Stat(credential); err != nil {
		t.Fatalf("explicit credential store was removed: %v", err)
	}
}

func TestStartPublicAccessInviteKeyUsesKeyStdinAndKeepsAccountPrivate(t *testing.T) {
	keyFile := filepath.Join(t.TempDir(), "invite-key")
	loginArgsFile := filepath.Join(t.TempDir(), "login-args")
	tunnelArgsFile := filepath.Join(t.TempDir(), "tunnel-args")
	t.Setenv("GNAR_KEY_FILE", keyFile)
	t.Setenv("GNAR_LOGIN_ARGS_FILE", loginArgsFile)
	t.Setenv("GNAR_ARGS_FILE", tunnelArgsFile)
	binary := writeScript(t, `#!/bin/sh
if [ "$1" = "login" ]; then
  printf '%s\n' "$@" > "$GNAR_LOGIN_ARGS_FILE"
  cat > "$GNAR_KEY_FILE"
  printf '%s\n' '{"type":"login_ok"}'
  exit 0
fi
printf '%s\n' "$@" > "$GNAR_ARGS_FILE"
printf '%s\n' '{"type":"tunnel_ready","public_url":"https://edge.example.com/invite/path"}'
sleep 30
`)
	manager := NewManager(slog.Default(), "http://127.0.0.1:8789", "", "", binary)
	status, err := manager.StartPublicAccessWithKey(
		"https://edge.example.com",
		"My-Host",
		LoginKeyInvite,
		[]byte("invite-secret"),
	)
	if err != nil {
		t.Fatalf("start invite public access: %v", err)
	}
	defer manager.Stop(KindGnar)
	if status.URL != "https://edge.example.com/invite/path/" {
		t.Fatalf("invite endpoint = %q", status.URL)
	}
	key, err := os.ReadFile(keyFile)
	if err != nil {
		t.Fatalf("read invite stdin: %v", err)
	}
	if string(key) != "invite-secret" {
		t.Fatalf("invite stdin = %q", key)
	}
	args, err := os.ReadFile(loginArgsFile)
	if err != nil {
		t.Fatalf("read login args: %v", err)
	}
	login := string(args)
	if !strings.Contains(login, "--key-stdin") || strings.Contains(login, "--enrollment-key-stdin") {
		t.Fatalf("invite login args = %q", login)
	}
	if !strings.Contains(login, "--account\nmy-host") {
		t.Fatalf("invite account args = %q", login)
	}
	if strings.Contains(login, "invite-secret") {
		t.Fatalf("invite key leaked into argv: %q", login)
	}
}

func TestStartPublicAccessRejectsShortInviteKeyBeforeLaunchingGnar(t *testing.T) {
	launched := filepath.Join(t.TempDir(), "launched")
	t.Setenv("GNAR_LAUNCHED", launched)
	binary := writeScript(t, `#!/bin/sh
touch "$GNAR_LAUNCHED"
exit 1
`)
	manager := NewManager(slog.Default(), "http://127.0.0.1:8789", "", "", binary)
	status, err := manager.StartPublicAccessWithKey(
		"https://edge.example.com",
		"host",
		LoginKeyInvite,
		[]byte("bilibili"),
	)
	if err == nil || !strings.Contains(err.Error(), "at least 12 characters") {
		t.Fatalf("short invite key error = %v, status=%#v", err, status)
	}
	if _, statErr := os.Stat(launched); !os.IsNotExist(statErr) {
		t.Fatalf("gnar launched for invalid invite key: %v", statErr)
	}
}

func TestStartPublicAccessApprovalKeyUsesEnrollmentContract(t *testing.T) {
	keyFile := filepath.Join(t.TempDir(), "approval-key")
	loginArgsFile := filepath.Join(t.TempDir(), "login-args")
	t.Setenv("GNAR_KEY_FILE", keyFile)
	t.Setenv("GNAR_LOGIN_ARGS_FILE", loginArgsFile)
	binary := writeScript(t, `#!/bin/sh
if [ "$1" = "login" ]; then
  printf '%s\n' "$@" > "$GNAR_LOGIN_ARGS_FILE"
  cat > "$GNAR_KEY_FILE"
  printf '%s\n' '{"type":"login_ok"}'
  exit 0
fi
printf '%s\n' '{"type":"tunnel_ready","public_url":"https://edge.example.com/approval"}'
sleep 30
`)
	manager := NewManager(slog.Default(), "http://127.0.0.1:8789", "", "", binary)
	status, err := manager.StartPublicAccessWithKey(
		"https://edge.example.com",
		"host",
		LoginKeyApproval,
		[]byte("approval-secret"),
	)
	if err != nil {
		t.Fatalf("start approval public access: %v", err)
	}
	defer manager.Stop(KindGnar)
	if status.URL == "" {
		t.Fatal("approval endpoint is empty")
	}
	key, err := os.ReadFile(keyFile)
	if err != nil {
		t.Fatalf("read approval stdin: %v", err)
	}
	if string(key) != "approval-secret" {
		t.Fatalf("approval stdin = %q", key)
	}
	args, err := os.ReadFile(loginArgsFile)
	if err != nil {
		t.Fatalf("read approval args: %v", err)
	}
	if !strings.Contains(string(args), "--enrollment-key-stdin") || strings.Contains(string(args), "--key-stdin") {
		t.Fatalf("approval login args = %q", args)
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

func TestSuccessfulGnarLoginClearsPreviousStoppedFailure(t *testing.T) {
	keyPath := filepath.Join(t.TempDir(), "gnar-key")
	loginCountPath := filepath.Join(t.TempDir(), "gnar-login-count")
	t.Setenv("GNAR_KEY_FILE", keyPath)
	t.Setenv("GNAR_LOGIN_COUNT", loginCountPath)
	binary := writeScript(t, `#!/bin/sh
if [ "$1" = "login" ]; then
  cat > "$GNAR_KEY_FILE"
  printf '%s\n' '{"type":"login_ok"}'
  exit 0
fi
count=0
if [ -f "$GNAR_LOGIN_COUNT" ]; then count=$(cat "$GNAR_LOGIN_COUNT"); fi
count=$((count + 1))
printf '%s' "$count" > "$GNAR_LOGIN_COUNT"
if [ "$count" = "1" ]; then
  printf '%s\n' '{"type":"error","message":"no persisted gnar token; enrollment required"}'
  exit 1
fi
printf '%s\n' '{"type":"tunnel_ready","public_url":"https://edge.example.com/warren"}'
sleep 30
`)
	manager := NewManager(slog.Default(), "http://127.0.0.1:8789", "", "", binary)

	failed, err := manager.StartPublicAccess("https://edge.example.com", "warren", nil)
	if err == nil || failed.Error == "" {
		t.Fatalf("initial token-backed start = %#v, err %v; want actionable failure", failed, err)
	}
	if current := manager.Status()[KindGnar]; current.Error == "" || current.Running {
		t.Fatalf("stopped failure status = %#v", current)
	}

	tested, err := manager.TestPublicAccess(
		"https://edge.example.com",
		"warren",
		LoginKeyApproval,
		[]byte("approval-secret"),
	)
	if err != nil {
		t.Fatalf("bootstrap login after failure: %v", err)
	}
	if !manager.GnarAuthenticated() || tested.Error != "" {
		t.Fatalf("authenticated test status = %#v, authenticated=%v", tested, manager.GnarAuthenticated())
	}
	if _, ok := manager.Status()[KindGnar]; ok {
		t.Fatalf("stale stopped failure remained after successful login: %#v", manager.Status()[KindGnar])
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
	for _, value := range []string{
		"invite-key=invite-secret-value",
		"approval key: approval-secret-value",
	} {
		redacted := redactGnarText(value)
		if strings.Contains(redacted, "secret-value") {
			t.Fatalf("secret was not redacted: %q", redacted)
		}
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
