package browser

import (
	"context"
	"encoding/json"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

// These tests cover the parts of the runtime that need no Chromium, so they run
// everywhere — including a machine with no browser installed, where the live
// tests skip.

func TestSanitizePathSegmentKeepsIDsInsideTheProfileRoot(t *testing.T) {
	cases := map[string]string{
		"abc123":                "abc123",
		"../escape":             "___escape",
		"a/b":                   "a_b",
		`a\b`:                   "a_b",
		strings.Repeat("x", 80): strings.Repeat("x", 80),
	}
	for input, want := range cases {
		if got := sanitizePathSegment(input); got != want {
			t.Errorf("sanitizePathSegment(%q) = %q, want %q", input, got, want)
		}
		if strings.Contains(sanitizePathSegment(input), "..") {
			t.Errorf("sanitizePathSegment(%q) still contains a parent reference", input)
		}
	}
}

func TestManagerSessionsAreOrderedAndRemovable(t *testing.T) {
	manager := NewManager(t.TempDir())
	for _, id := range []string{"s-c", "s-a", "s-b"} {
		manager.mu.Lock()
		manager.sessions[id] = newSession(manager, id, "", "", "terminalGroup", true, api.BrowserViewport{Width: DefaultViewportWidth, Height: DefaultViewportHeight})
		manager.mu.Unlock()
	}
	ids := make([]string, 0, 3)
	for _, session := range manager.Sessions() {
		ids = append(ids, session.id)
	}
	if strings.Join(ids, ",") != "s-a,s-b,s-c" {
		t.Fatalf("roster order = %v, want sorted", ids)
	}

	var ended []string
	var mu sync.Mutex
	manager.SetEndHandler(func(id string) {
		mu.Lock()
		defer mu.Unlock()
		ended = append(ended, id)
	})
	manager.remove("s-b")
	manager.remove("s-b")
	mu.Lock()
	defer mu.Unlock()
	if len(ended) != 1 || ended[0] != "s-b" {
		t.Fatalf("end handler fired %v, want exactly one call for s-b", ended)
	}
	if _, ok := manager.Session("s-b"); ok {
		t.Fatal("removed session is still reachable")
	}
}

func TestManagerStartRejectsAnIDThatIsAlreadyRunning(t *testing.T) {
	manager := NewManager("")
	manager.mu.Lock()
	manager.sessions["dup"] = newSession(manager, "dup", "", "", "terminalGroup", true, api.BrowserViewport{Width: DefaultViewportWidth, Height: DefaultViewportHeight})
	manager.mu.Unlock()

	if _, err := manager.Start(context.Background(), StartOptions{SessionID: "dup", Scope: "terminalGroup"}); err == nil {
		t.Fatal("starting a duplicate session id must fail")
	}
	if _, err := manager.Start(context.Background(), StartOptions{SessionID: ""}); err == nil {
		t.Fatal("starting without a session id must fail")
	}
}

func TestActionTimeoutClampsCallerValues(t *testing.T) {
	if got := actionTimeout(0); got != defaultCDPTimeout {
		t.Fatalf("actionTimeout(0) = %s, want the default %s", got, defaultCDPTimeout)
	}
	if got := actionTimeout(-5); got != defaultCDPTimeout {
		t.Fatalf("actionTimeout(-5) = %s, want the default", got)
	}
	if got := actionTimeout(2500); got != 2500*time.Millisecond {
		t.Fatalf("actionTimeout(2500) = %s", got)
	}
	if got := actionTimeout(1 << 40); got != 600*time.Second {
		t.Fatalf("actionTimeout(huge) = %s, want the 10 minute ceiling", got)
	}
}

func TestVirtualKeysCoverEveryNamedKey(t *testing.T) {
	for name, spec := range keySpecs {
		if spec.Key == "" || spec.Code == "" {
			t.Errorf("key %q has no key or code", name)
		}
		if spec.VirtualKey == 0 {
			t.Errorf("key %q has no virtual key code", name)
		}
		if _, ok := macNativeKeyCodes[spec.VirtualKey]; !ok {
			t.Errorf("key %q (vk %d) has no macOS native code", name, spec.VirtualKey)
		}
		if native := virtualKeyForPlatform(spec.VirtualKey); native == 0 {
			t.Errorf("key %q maps to a zero native code", name)
		}
	}
}

func TestVirtualKeyForName(t *testing.T) {
	if got := virtualKeyForName("a"); got != 65 {
		t.Errorf("virtualKeyForName(\"a\") = %d, want 65", got)
	}
	if got := virtualKeyForName("7"); got != 55 {
		t.Errorf("virtualKeyForName(\"7\") = %d, want 55", got)
	}
	if got := virtualKeyForName(""); got != 0 {
		t.Errorf("virtualKeyForName(\"\") = %d, want 0", got)
	}
	if got := virtualKeyForName("ab"); got != 0 {
		t.Errorf("virtualKeyForName(\"ab\") = %d, want 0", got)
	}
}

func TestJSEncodingEscapesQuotesAndBackslashes(t *testing.T) {
	// A selector containing a quote must not be able to break out of the string
	// literal it is embedded in, or it becomes script injection.
	if got := jsString(`a"b\c`); got != `"a\"b\\c"` {
		t.Fatalf("jsString = %s", got)
	}
	if got := jsArray([]string{"a", `b"c`}); got != `["a","b\"c"]` {
		t.Fatalf("jsArray = %s", got)
	}
}

func TestExpressionsEmbedTheirArguments(t *testing.T) {
	if !strings.Contains(snapshotExpression(42, true), "42") {
		t.Fatal("snapshot expression does not carry its node bound")
	}
	if !strings.Contains(snapshotExpression(42, true), "true && !interactive") {
		t.Fatal("interactive-only snapshot did not enable the filter")
	}
	if !strings.Contains(snapshotExpression(42, false), "false && !interactive") {
		t.Fatal("full snapshot did not disable the interactive filter")
	}
	if got := waitExpression("#a", "", "", ""); strings.Contains(got, "undefined") {
		t.Fatalf("wait expression leaks an undefined argument: %s", got)
	}
	// Every expression must be self-contained: no template literals that would
	// need escaping, and no reference to a Go helper.
	for _, expression := range []string{
		pointExpression(`#it"s`, "text"),
		focusExpression("#field"),
		clearFieldExpression("#field"),
		selectExpression("#field", []string{"a"}),
		scrollIntoViewExpression("", "Sign in"),
	} {
		if strings.Contains(expression, "${") {
			t.Fatalf("expression contains a template literal: %s", expression)
		}
	}
}

func TestFirstNonEmpty(t *testing.T) {
	if got := firstNonEmpty("", "  ", "x"); got != "x" {
		t.Fatalf("firstNonEmpty = %q, want %q", got, "x")
	}
	if got := firstNonEmpty(); got != "" {
		t.Fatalf("firstNonEmpty() = %q, want empty", got)
	}
}

// The viewer page is JavaScript, so the field name it sends is the only contract
// between the page's devicePixelRatio and the Host's rendering density. Both
// directions are asserted here, because a renamed tag would leave the page
// reporting a density nobody reads: the live view would stay at the layout size
// and nothing would report an error.
func TestViewportDeviceScaleFactorTravelsAsDeviceScaleFactor(t *testing.T) {
	encoded, err := json.Marshal(api.BrowserAction{
		Action:            api.BrowserActionViewport,
		Width:             800,
		Height:            600,
		DeviceScaleFactor: 2,
	})
	if err != nil {
		t.Fatalf("encode viewport action: %v", err)
	}
	if !strings.Contains(string(encoded), `"deviceScaleFactor":2`) {
		t.Fatalf("viewport action did not carry the density: %s", encoded)
	}

	var decoded api.BrowserAction
	if err := json.Unmarshal([]byte(`{"action":"viewport","width":800,"height":600,"deviceScaleFactor":2}`), &decoded); err != nil {
		t.Fatalf("decode viewport action: %v", err)
	}
	if decoded.DeviceScaleFactor != 2 {
		t.Fatalf("decoded density = %v, want 2", decoded.DeviceScaleFactor)
	}
}
