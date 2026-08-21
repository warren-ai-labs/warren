package runtime

import (
	"os"
	"testing"
)

func TestSanitizeEnvironmentRemovesAgentPagerOverrides(t *testing.T) {
	t.Setenv("GIT_PAGER", "cat")
	t.Setenv("PAGER", "cat")
	t.Setenv("GH_PAGER", "cat")
	t.Setenv("TERM", "dumb")
	t.Setenv("NO_COLOR", "1")

	SanitizeEnvironment()

	for _, key := range []string{"GIT_PAGER", "PAGER", "GH_PAGER"} {
		if got := os.Getenv(key); got != "" {
			t.Errorf("%s = %q, want unset", key, got)
		}
	}
	if got := os.Getenv("TERM"); got != DefaultTerm {
		t.Errorf("TERM = %q, want %q", got, DefaultTerm)
	}
	if _, ok := os.LookupEnv("NO_COLOR"); ok {
		t.Error("NO_COLOR remained set; want it unset")
	}
}

func TestSanitizeEnvironmentTreatsEmptyPagerAsDisabled(t *testing.T) {
	t.Setenv("GIT_PAGER", "")
	t.Setenv("PAGER", "")
	t.Setenv("GH_PAGER", "")
	t.Setenv("TERM", "")

	SanitizeEnvironment()

	for _, key := range []string{"GIT_PAGER", "PAGER", "GH_PAGER"} {
		if got := os.Getenv(key); got != "" {
			t.Errorf("%s = %q, want unset", key, got)
		}
	}
	if got := os.Getenv("TERM"); got != DefaultTerm {
		t.Errorf("TERM = %q, want %q", got, DefaultTerm)
	}
}

func TestSanitizeEnvironmentKeepsUserPagerAndTerm(t *testing.T) {
	t.Setenv("GIT_PAGER", "less -R")
	t.Setenv("PAGER", "less")
	t.Setenv("GH_PAGER", "less")
	t.Setenv("TERM", "xterm-ghostty")

	SanitizeEnvironment()

	for key, want := range map[string]string{
		"GIT_PAGER": "less -R",
		"PAGER":     "less",
		"GH_PAGER":  "less",
		"TERM":      "xterm-ghostty",
	} {
		if got := os.Getenv(key); got != want {
			t.Errorf("%s = %q, want %q", key, got, want)
		}
	}
}
