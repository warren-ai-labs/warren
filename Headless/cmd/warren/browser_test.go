package main

import (
	"strings"
	"testing"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

func browserAction(t *testing.T, args ...string) api.BrowserAction {
	t.Helper()
	params := parseFlags(args, browserActionValueFlags)
	request, err := browserActionParams(params)
	if err != nil {
		t.Fatalf("browserActionParams(%q): %v", args, err)
	}
	action, ok := request["action"].(api.BrowserAction)
	if !ok {
		t.Fatalf("request action = %T, want api.BrowserAction", request["action"])
	}
	return action
}

// `--text` is a bare boolean for the transcript readers, and parseFlags honors
// that globally. A browser action needs the string, so the value-flag override
// has to win or the element text lands in the positionals instead of the action.
func TestBrowserActionTextIsAValueNotABareBoolean(t *testing.T) {
	action := browserAction(t, "session-1", "click", "--text", "Sign in")
	if action.Action != "click" {
		t.Fatalf("Action = %q, want click", action.Action)
	}
	if action.Text != "Sign in" {
		t.Fatalf("Text = %q, want Sign in", action.Text)
	}
}

// parseFlags hands every value-taking flag a string, including a number the
// caller wrote unquoted.
func TestBrowserActionNumbersArriveAsStrings(t *testing.T) {
	action := browserAction(t, "session-1", "wait", "--timeout", "5000", "--dx", "-40", "--limit", "5")
	if action.TimeoutMs != 5000 {
		t.Fatalf("TimeoutMs = %d, want 5000", action.TimeoutMs)
	}
	if action.DX != -40 {
		t.Fatalf("DX = %d, want -40", action.DX)
	}
	if action.Limit != 5 {
		t.Fatalf("Limit = %d, want 5", action.Limit)
	}
}

// A boolean browser flag must not swallow the token after it, because that token
// is usually the value of the next flag.
func TestBrowserActionBooleanDoesNotConsumeTheNextFlag(t *testing.T) {
	action := browserAction(t, "session-1", "type", "--selector", "#name", "--value", "warren", "--clear", "--delay", "10")
	if !action.ClearFirst {
		t.Fatal("ClearFirst = false, want true")
	}
	if action.Selector != "#name" {
		t.Fatalf("Selector = %q, want #name", action.Selector)
	}
	if action.Value != "warren" {
		t.Fatalf("Value = %q, want warren", action.Value)
	}
	if action.DelayMs != 10 {
		t.Fatalf("DelayMs = %d, want 10", action.DelayMs)
	}
}

func TestBrowserActionExplicitBooleanSpellings(t *testing.T) {
	if action := browserAction(t, "session-1", "snapshot", "--interactive=true"); !action.InteractiveOnly {
		t.Fatal("--interactive=true did not set InteractiveOnly")
	}
	if action := browserAction(t, "session-1", "snapshot", "--interactive=false"); action.InteractiveOnly {
		t.Fatal("--interactive=false set InteractiveOnly")
	}
}

func TestBrowserActionSelectValuesSplitOnCommas(t *testing.T) {
	action := browserAction(t, "session-1", "select", "--selector", "#lang", "--values", "go, rust ,swift")
	want := []string{"go", "rust", "swift"}
	if len(action.Values) != len(want) {
		t.Fatalf("Values = %q, want %q", action.Values, want)
	}
	for index, value := range want {
		if action.Values[index] != value {
			t.Fatalf("Values[%d] = %q, want %q", index, action.Values[index], value)
		}
	}
}

func TestBrowserActionScreenshotFormat(t *testing.T) {
	if action := browserAction(t, "session-1", "screenshot", "--path", "/tmp/x.png"); action.Format != "" {
		t.Fatalf("Format = %q, want empty so the runtime default applies", action.Format)
	}
	if action := browserAction(t, "session-1", "screenshot", "--format", "jpeg", "--quality", "50"); action.Format != "jpeg" || action.Quality != 50 {
		t.Fatalf("Format = %q Quality = %d, want jpeg 50", action.Format, action.Quality)
	}
}

func TestBrowserActionRejectsUnusableValues(t *testing.T) {
	tests := []struct {
		name string
		args []string
		want string
	}{
		{name: "timeout", args: []string{"session-1", "wait", "--timeout", "soon"}, want: "--timeout must be a number"},
		{name: "interactive", args: []string{"session-1", "snapshot", "--interactive", "maybe"}, want: "--interactive must be true or false"},
		{name: "url", args: []string{"session-1", "navigate", "--url", "   "}, want: "--url requires a value"},
		{name: "values", args: []string{"session-1", "select", "--values", " , "}, want: "--values requires at least one value"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			_, err := browserActionParams(parseFlags(test.args, browserActionValueFlags))
			if err == nil {
				t.Fatalf("browserActionParams(%q) succeeded, want an error", test.args)
			}
			if !strings.Contains(err.Error(), test.want) {
				t.Fatalf("error = %v, want it to contain %q", err, test.want)
			}
		})
	}
}

func TestBrowserActionKeepsTheActionNamePositional(t *testing.T) {
	params := parseFlags([]string{"session-1", "evaluate", "--expression", "1+1"}, browserActionValueFlags)
	request, err := browserActionParams(params)
	if err != nil {
		t.Fatalf("browserActionParams: %v", err)
	}
	if request["id"] != "session-1" {
		t.Fatalf("id = %v, want session-1", request["id"])
	}
	if positions := positionals(params); len(positions) != 2 || positions[1] != "evaluate" {
		t.Fatalf("positionals = %q, want [session-1 evaluate]", positions)
	}
}

func TestBrowserRowsKeepsOnlyRunningBrowserSessions(t *testing.T) {
	state := api.State{Sessions: []api.Session{
		{ID: "b-1", Kind: "browser", Lifecycle: "running", Title: "Chrome"},
		{ID: "b-2", Kind: "browser", Lifecycle: "ended", Title: "Dead browser"},
		{ID: "s-1", Kind: "shell", Lifecycle: "running", Title: "zsh"},
	}}
	rows := browserRows(state, nil)
	if len(rows) != 1 || rows[0].ID != "b-1" {
		t.Fatalf("rows = %+v, want only b-1", rows)
	}
	if cells := browserRowCells(rows[0]); cells[0] != "b-1" {
		t.Fatalf("cells = %q, want the ID first", cells)
	}
}

func TestBrowserRowsFilterByScopeAndSearch(t *testing.T) {
	state := api.State{Sessions: []api.Session{
		{ID: "b-1", Kind: "browser", Lifecycle: "running", WorkspaceID: "w-1", Title: "Login flow"},
		{ID: "b-2", Kind: "browser", Lifecycle: "running", TerminalGroupID: "g-1", CustomTitle: "Docs"},
	}}
	if rows := browserRows(state, map[string]any{"workspace": "w-1"}); len(rows) != 1 || rows[0].ID != "b-1" {
		t.Fatalf("workspace filter rows = %+v, want b-1", rows)
	}
	if rows := browserRows(state, map[string]any{"group": "g-1"}); len(rows) != 1 || rows[0].ID != "b-2" {
		t.Fatalf("group filter rows = %+v, want b-2", rows)
	}
	if rows := browserRows(state, map[string]any{"search": "docs"}); len(rows) != 1 || rows[0].ID != "b-2" {
		t.Fatalf("search rows = %+v, want b-2 by custom title", rows)
	}
}

func TestBrowserViewportFromParams(t *testing.T) {
	viewport, err := browserViewportFromParams(map[string]any{"width": "1280", "height": float64(800)})
	if err != nil {
		t.Fatalf("browserViewportFromParams: %v", err)
	}
	if viewport.Width != 1280 || viewport.Height != 800 {
		t.Fatalf("viewport = %+v, want 1280x800", viewport)
	}
	if viewport, err = browserViewportFromParams(nil); err != nil || viewport.Width != 0 || viewport.Height != 0 {
		t.Fatalf("empty viewport = %+v err = %v, want the zero viewport", viewport, err)
	}
	if _, err = browserViewportFromParams(map[string]any{"width": "wide"}); err == nil {
		t.Fatal("a non-numeric width was accepted")
	}
}
