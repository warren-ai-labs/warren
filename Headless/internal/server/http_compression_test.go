package server

import (
	"bytes"
	"compress/gzip"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/gorilla/websocket"
)

func TestHTTPGzipCompression(t *testing.T) {
	tempDir := t.TempDir()
	t.Setenv("WARREN_WEB_ROOT", tempDir)
	largeHTML := strings.Repeat("<div>Warren Web Platform Payload Optimization Test</div>\n", 50)
	if err := os.WriteFile(filepath.Join(tempDir, "index.html"), []byte(largeHTML), 0644); err != nil {
		t.Fatalf("write index.html: %v", err)
	}

	state := newStateWithSession(t, "s1", "ghostline")
	service := &Service{Store: state}
	server := NewHTTPServer(service, "test-secret", nil)
	ts := httptest.NewServer(server.Handler())
	defer ts.Close()

	// 1. Request with Accept-Encoding: gzip should return compressed content
	req, err := http.NewRequest(http.MethodGet, ts.URL+"/", nil)
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	req.Header.Set("Accept-Encoding", "gzip")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("do request: %v", err)
	}
	defer resp.Body.Close()

	if encoding := resp.Header.Get("Content-Encoding"); encoding != "gzip" {
		t.Fatalf("expected Content-Encoding gzip, got %q", encoding)
	}
	if vary := resp.Header.Get("Vary"); !strings.Contains(vary, "Accept-Encoding") {
		t.Fatalf("expected Vary header to contain Accept-Encoding, got %q", vary)
	}

	gzReader, err := gzip.NewReader(resp.Body)
	if err != nil {
		t.Fatalf("gzip.NewReader: %v", err)
	}
	defer gzReader.Close()
	decompressed, err := io.ReadAll(gzReader)
	if err != nil {
		t.Fatalf("read decompressed body: %v", err)
	}
	if string(decompressed) != largeHTML {
		t.Fatalf("decompressed body mismatch, length got %d want %d", len(decompressed), len(largeHTML))
	}

	// 2. Request without Accept-Encoding: gzip should return uncompressed content
	reqPlain, err := http.NewRequest(http.MethodGet, ts.URL+"/", nil)
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	respPlain, err := http.DefaultClient.Do(reqPlain)
	if err != nil {
		t.Fatalf("do request: %v", err)
	}
	defer respPlain.Body.Close()

	if encoding := respPlain.Header.Get("Content-Encoding"); encoding != "" {
		t.Fatalf("expected empty Content-Encoding, got %q", encoding)
	}
	plainBody, err := io.ReadAll(respPlain.Body)
	if err != nil {
		t.Fatalf("read plain body: %v", err)
	}
	if string(plainBody) != largeHTML {
		t.Fatalf("plain body mismatch")
	}

	// 3. Request for API state with gzip should be compressed
	reqState, err := http.NewRequest(http.MethodGet, ts.URL+"/v1/state", nil)
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	reqState.Header.Set("Accept-Encoding", "gzip")
	reqState.Header.Set("Authorization", "Bearer test-secret")

	respState, err := http.DefaultClient.Do(reqState)
	if err != nil {
		t.Fatalf("do request: %v", err)
	}
	defer respState.Body.Close()

	if encoding := respState.Header.Get("Content-Encoding"); encoding != "gzip" {
		t.Fatalf("expected Content-Encoding gzip for /v1/state, got %q", encoding)
	}
	gzReaderState, err := gzip.NewReader(respState.Body)
	if err != nil {
		t.Fatalf("gzip.NewReader for state: %v", err)
	}
	defer gzReaderState.Close()
	decompressedState, err := io.ReadAll(gzReaderState)
	if err != nil {
		t.Fatalf("read decompressed state: %v", err)
	}
	if !bytes.Contains(decompressedState, []byte(`"sessions"`)) {
		t.Fatalf("decompressed state missing sessions key: %s", decompressedState)
	}
}

func TestWebSocketCompressionNegotiation(t *testing.T) {
	state := newStateWithSession(t, "s1", "ghostline")
	service := &Service{Store: state}
	server := NewHTTPServer(service, "test-secret", nil)
	ts := httptest.NewServer(server.Handler())
	defer ts.Close()

	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/v1/ws"

	// 1. Dial with compression enabled
	dialer := *websocket.DefaultDialer
	dialer.EnableCompression = true

	conn, resp, err := dialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatalf("dial with compression: %v", err)
	}
	defer conn.Close()

	// Verify Sec-WebSocket-Extensions header was negotiated
	exts := resp.Header.Get("Sec-WebSocket-Extensions")
	if !strings.Contains(exts, "permessage-deflate") {
		t.Fatalf("expected permessage-deflate in Sec-WebSocket-Extensions, got %q", exts)
	}

	// 2. Perform authentication
	if err := conn.WriteJSON(api.Envelope{
		Type:                 "auth",
		Token:                "test-secret",
		Version:              api.Version,
		TerminalStateFormats: []string{terminalStateFormatANSI},
	}); err != nil {
		t.Fatalf("write auth: %v", err)
	}
	var welcome map[string]any
	if err := conn.ReadJSON(&welcome); err != nil {
		t.Fatalf("read welcome: %v", err)
	}
	if welcome["t"] != "welcome" {
		t.Fatalf("expected welcome envelope, got %#v", welcome)
	}

	// Host sends initial roster broadcast right after welcome
	var initialRoster map[string]any
	if err := conn.ReadJSON(&initialRoster); err != nil {
		t.Fatalf("read initial roster: %v", err)
	}
	if initialRoster["t"] != "roster" {
		t.Fatalf("expected initial roster, got %#v", initialRoster)
	}
}
