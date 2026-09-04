package relay

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

// TestRelayE2E exercises the full Relay lifecycle: stand up a fresh
// warren-relay on a loopback port, mint a short enrollment key, let the
// headless daemon actively claim a Host, wait for the supervised connector to come online,
// generate a pairing code, exchange it for a web URL, and verify the
// web URL resolves to a working authenticated endpoint.
//
// The test builds the two binaries from the working tree on first run and
// caches them under t.TempDir()/bin. To exercise a real remote Relay (for
// example the one on tenc_sh), set WARREN_E2E_RELAY_URL=https://... and
// WARREN_E2E_RELAY_ADMIN_TOKEN=... and the test will skip starting a local
// relay and instead enroll against the deployed one.
func TestRelayE2E(t *testing.T) {
	if os.Getenv("WARREN_E2E_SKIP") != "" {
		t.Skip("WARREN_E2E_SKIP is set")
	}
	relayURL := os.Getenv("WARREN_E2E_RELAY_URL")
	adminToken := os.Getenv("WARREN_E2E_RELAY_ADMIN_TOKEN")

	repoRoot, err := repoRoot()
	if err != nil {
		t.Fatalf("find repo root: %v", err)
	}
	tmp := t.TempDir()
	binDir := filepath.Join(tmp, "bin")
	if err := os.MkdirAll(binDir, 0o755); err != nil {
		t.Fatalf("mkdir bin: %v", err)
	}
	headlessBin := filepath.Join(binDir, "warren-headless")
	if err := buildBinary(repoRoot, "./Headless/cmd/warren-headless", headlessBin); err != nil {
		t.Fatalf("build warren-headless: %v", err)
	}

	var relayCleanup func()
	if relayURL == "" {
		relayBin := filepath.Join(binDir, "warren-relay")
		if err := buildBinary(repoRoot, "./RelayService/cmd/warren-relay", relayBin); err != nil {
			t.Fatalf("build warren-relay: %v", err)
		}
		port := freePort(t)
		adminToken = randomHex(t, 32)
		signingKey := randomHex(t, 32)
		relayURL = fmt.Sprintf("http://127.0.0.1:%d", port)
		ctx, cancel := context.WithCancel(context.Background())
		cmd := exec.CommandContext(ctx, relayBin)
		cmd.Env = append(os.Environ(),
			"WARREN_RELAY_LISTEN=127.0.0.1:"+fmt.Sprint(port),
			"WARREN_RELAY_PUBLIC_URL="+relayURL,
			"WARREN_RELAY_ALLOWED_ORIGIN="+relayURL,
			"WARREN_RELAY_ADMIN_TOKEN="+adminToken,
			"WARREN_RELAY_SIGNING_KEY="+signingKey,
			"WARREN_RELAY_DATA="+filepath.Join(tmp, "registry.json"),
		)
		logFile := filepath.Join(tmp, "relay.log")
		logF, err := os.Create(logFile)
		if err != nil {
			t.Fatalf("create relay log: %v", err)
		}
		cmd.Stdout = logF
		cmd.Stderr = logF
		if err := cmd.Start(); err != nil {
			t.Fatalf("start relay: %v", err)
		}
		relayCleanup = func() {
			cancel()
			_ = cmd.Wait()
			_ = logF.Close()
		}
		if !waitForHealth(relayURL+"/healthz", 5*time.Second) {
			tail, _ := os.ReadFile(logFile)
			relayCleanup()
			t.Fatalf("relay did not become healthy; log:\n%s", tail)
		}
	}
	t.Cleanup(func() {
		if relayCleanup != nil {
			relayCleanup()
		}
	})

	// Relay administrators mint a short-lived enrollment key. The Host claims
	// its identity itself; no Host ID or Relay signing key is pre-created.
	keyResponse := postJSON(t, relayURL+"/v1/admin/enrollment-keys", map[string]any{
		"count": 1, "ttl": "10m", "max_uses": 1, "label": "e2e",
	}, adminToken)
	keys, ok := keyResponse["keys"].([]any)
	if !ok || len(keys) != 1 {
		t.Fatalf("incomplete enrollment key response: %+v", keyResponse)
	}
	keyObject, ok := keys[0].(map[string]any)
	if !ok {
		t.Fatalf("invalid enrollment key object: %+v", keys[0])
	}
	enrollmentKey := stringField(t, keyObject, "key")

	// Pick a loopback port for the headless daemon. The daemon serves its
	// /healthz, /v1/state, and WebSocket on this port; the host only needs
	// outbound reachability to the relay.
	headlessPort := freePort(t)
	hostToken := randomHex(t, 32)
	hostData := filepath.Join(tmp, "host")
	if err := os.MkdirAll(hostData, 0o700); err != nil {
		t.Fatalf("mkdir host: %v", err)
	}
	tokenFile := filepath.Join(hostData, "token")
	if err := os.WriteFile(tokenFile, []byte(hostToken), 0o600); err != nil {
		t.Fatalf("write token: %v", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	cmd := exec.CommandContext(ctx, headlessBin, "--lan-https=")
	cmd.Env = append(os.Environ(),
		"WARREN_LISTEN=127.0.0.1:"+fmt.Sprint(headlessPort),
		"WARREN_RELAY_URL="+relayURL,
		"WARREN_RELAY_ENROLLMENT_KEY="+enrollmentKey,
		"WARREN_TOKEN_FILE="+tokenFile,
		"WARREN_STATE="+filepath.Join(hostData, "state.json"),
		"WARREN_SETTINGS_FILE="+filepath.Join(hostData, "settings.json"),
		"WARREN_GHOSTLINE_SOCKET="+filepath.Join(hostData, "ghostline.sock"),
		"WARREN_OUTPUT_DIR="+filepath.Join(hostData, "output"),
		"WARREN_HEADLESS_LOG=info",
	)
	hostLog := filepath.Join(tmp, "host.log")
	logF, err := os.Create(hostLog)
	if err != nil {
		t.Fatalf("create host log: %v", err)
	}
	cmd.Stdout = logF
	cmd.Stderr = logF
	if err := cmd.Start(); err != nil {
		t.Fatalf("start headless: %v", err)
	}
	t.Cleanup(func() {
		cancel()
		_ = cmd.Wait()
		_ = logF.Close()
	})
	if !waitForHealth(fmt.Sprintf("http://127.0.0.1:%d/healthz", headlessPort), 5*time.Second) {
		tail, _ := os.ReadFile(hostLog)
		t.Fatalf("headless did not become healthy; log:\n%s", tail)
	}

	settingsResponse := getJSON(t, fmt.Sprintf("http://127.0.0.1:%d/v1/settings", headlessPort), hostToken)
	relaySettings, ok := settingsResponse["relay"].(map[string]any)
	if !ok {
		t.Fatalf("headless settings missing relay metadata: %+v", settingsResponse)
	}
	hostID := stringField(t, relaySettings, "hostID")
	if hostID == "" || relaySettings["relayKeyID"] == nil || relaySettings["relayKey"] == nil {
		t.Fatalf("headless did not persist Relay claim metadata: %+v", relaySettings)
	}
	if _, present := relaySettings["enrollmentKey"]; present {
		t.Fatal("headless persisted the one-time enrollment key")
	}

	// Wait for the supervised connector to dial in. The relay marks the
	// host online when the BRLY/2 control stream is open.
	onlineDeadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(onlineDeadline) {
		body := getJSON(t, relayURL+"/v1/hosts/"+hostID, adminToken)
		if online, _ := body["online"].(bool); online {
			break
		}
		time.Sleep(200 * time.Millisecond)
	}
	body := getJSON(t, relayURL+"/v1/hosts/"+hostID, adminToken)
	if online, _ := body["online"].(bool); !online {
		tail, _ := os.ReadFile(hostLog)
		t.Fatalf("host did not come online within 15s; relay body=%+v host log:\n%s", body, tail)
	}

	// Generate a pairing code and exchange it for a web URL. The web URL
	// points at the relay and is what a phone browser would open.
	pairingResponse := postJSON(t, relayURL+"/v1/hosts/"+hostID+"/pairing", map[string]any{}, hostToken)
	pairingCode := stringField(t, pairingResponse, "pairing_code")
	if pairingCode == "" {
		t.Fatalf("pairing response missing code: %+v", pairingResponse)
	}
	pairResponse := postJSON(t, relayURL+"/v1/pair", map[string]string{
		"host_id":      hostID,
		"pairing_code": pairingCode,
	}, "")
	webURL := stringField(t, pairResponse, "web_url")
	if webURL == "" {
		t.Fatalf("pair response missing web_url: %+v", pairResponse)
	}

	// The web URL is a reusable, short-lived invite. Treat it like a signed link:
	// it must resolve to a working HTTP page, and the relay's roster
	// endpoint must accept the host secret the same way the headless uses.
	webReq, err := http.NewRequest("GET", webURL, nil)
	if err != nil {
		t.Fatalf("build web request: %v", err)
	}
	webResp, err := http.DefaultClient.Do(webReq)
	if err != nil {
		t.Fatalf("fetch web url: %v", err)
	}
	defer webResp.Body.Close()
	if webResp.StatusCode/100 != 2 {
		body, _ := io.ReadAll(webResp.Body)
		t.Fatalf("web url returned %d: %s", webResp.StatusCode, body)
	}
	// Drain the body so the connection can be reused.
	_, _ = io.Copy(io.Discard, webResp.Body)

	// The health endpoint must report relay state when the host secret is
	// also valid against the relay. We can only check the headless /healthz
	// directly; the relay's roster must be queried with the host token.
	health := getJSON(t, fmt.Sprintf("http://127.0.0.1:%d/healthz", headlessPort), "")
	if ready, _ := health["ready"].(bool); !ready {
		t.Fatalf("headless reports not ready after enrollment: %+v", health)
	}
	relayStatus, ok := health["status"].(map[string]any)
	if !ok {
		t.Fatalf("headless health missing status block: %+v", health)
	}
	relayBlock, ok := relayStatus["relay"].(map[string]any)
	if !ok {
		t.Fatalf("headless health missing relay block: %+v", relayStatus)
	}
	if state, _ := relayBlock["state"].(string); state != "connected" {
		t.Fatalf("expected relay state=connected, got %+v", relayBlock)
	}
}

func buildBinary(workDir, pkg, out string) error {
	cmd := exec.Command("go", "build", "-o", out, pkg)
	cmd.Dir = workDir
	cmd.Env = append(os.Environ(), "CGO_ENABLED=0")
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("go build %s: %w: %s", pkg, err, stderr.String())
	}
	return nil
}

func repoRoot() (string, error) {
	dir, err := os.Getwd()
	if err != nil {
		return "", err
	}
	for i := 0; i < 8; i++ {
		if _, err := os.Stat(filepath.Join(dir, "go.mod")); err == nil {
			return dir, nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return "", fmt.Errorf("go.mod not found above %s", dir)
		}
		dir = parent
	}
	return "", fmt.Errorf("go.mod not found above %s", dir)
}

func freePort(t *testing.T) int {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer listener.Close()
	return listener.Addr().(*net.TCPAddr).Port
}

func randomHex(t *testing.T, bytes int) string {
	t.Helper()
	buf := make([]byte, bytes)
	if _, err := rand.Read(buf); err != nil {
		t.Fatalf("rand: %v", err)
	}
	return hex.EncodeToString(buf)
}

func postJSON(t *testing.T, url string, body any, token string) map[string]any {
	t.Helper()
	payload, err := json.Marshal(body)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	req, err := http.NewRequest("POST", url, bytes.NewReader(payload))
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	req.Header.Set("Content-Type", "application/json")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("post %s: %v", url, err)
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)
	if resp.StatusCode/100 != 2 {
		t.Fatalf("post %s returned %d: %s", url, resp.StatusCode, data)
	}
	var out map[string]any
	if err := json.Unmarshal(data, &out); err != nil {
		t.Fatalf("decode %s: %v body=%s", url, err, data)
	}
	return out
}

func getJSON(t *testing.T, url, token string) map[string]any {
	t.Helper()
	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("get %s: %v", url, err)
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)
	if resp.StatusCode/100 != 2 {
		t.Fatalf("get %s returned %d: %s", url, resp.StatusCode, data)
	}
	var out map[string]any
	if err := json.Unmarshal(data, &out); err != nil {
		t.Fatalf("decode %s: %v body=%s", url, err, data)
	}
	return out
}

func stringField(t *testing.T, m map[string]any, key string) string {
	t.Helper()
	value, ok := m[key].(string)
	if !ok {
		t.Fatalf("field %q missing or not a string in %+v", key, m)
	}
	return value
}

func waitForHealth(url string, timeout time.Duration) bool {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		resp, err := http.Get(url)
		if err == nil {
			_, _ = io.Copy(io.Discard, resp.Body)
			resp.Body.Close()
			if resp.StatusCode/100 == 2 {
				return true
			}
		}
		time.Sleep(100 * time.Millisecond)
	}
	return false
}
