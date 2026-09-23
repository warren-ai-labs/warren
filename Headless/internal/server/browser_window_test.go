package server

import "testing"

// A browser Session is rendered inside Warren from its own frame stream, so a
// create request that says nothing about windows must not open one: a separate
// Chromium window puts the page where Warren cannot draw it, and the Session's
// viewer then shows a second copy of the same page.
//
// The assertion is on the default specifically. A request carrying no `window`
// key and a request carrying `window: false` are different inputs that must
// reach the same answer, because the first is every ordinary caller and the
// second is a client that serializes its booleans either way.
func TestBrowserCreateRunsWithNoWindowUnlessAsked(t *testing.T) {
	for _, testCase := range []struct {
		name     string
		params   map[string]any
		headless bool
	}{
		{"no window key", map[string]any{}, true},
		{"window false", map[string]any{"window": false}, true},
		{"window true", map[string]any{"window": true}, false},
		{"window true as a string", map[string]any{"window": "true"}, false},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			headless, err := browserHeadlessFromParams(testCase.params)
			if err != nil {
				t.Fatalf("browserHeadlessFromParams(%#v) = %v", testCase.params, err)
			}
			if headless != testCase.headless {
				t.Fatalf("headless = %t, want %t for %#v", headless, testCase.headless, testCase.params)
			}
		})
	}

	// A value that is not a boolean is a caller mistake. Answering it as "no
	// window" would silently launch the opposite of what was asked for.
	if _, err := browserHeadlessFromParams(map[string]any{"window": "yes please"}); err == nil {
		t.Fatal("a non-boolean window value was accepted")
	}
}
