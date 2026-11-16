package title

import (
	"strings"
	"testing"
)

// The fallback names a Session from the person's own first message. These cases
// are the scaffolding that has actually turned up at the head of one.
func TestLocalLabelKeepsThePersonsWords(t *testing.T) {
	cases := []struct {
		name string
		user string
		want string
	}{
		{
			name: "plain request",
			user: "Fix the reconnect flow",
			want: "Fix the reconnect flow",
		},
		{
			name: "context block leads",
			user: "<environment_context>\n  <cwd>/work/warren</cwd>\n</environment_context>\nFix the reconnect flow",
			want: "Fix the reconnect flow",
		},
		{
			name: "instructions block leads",
			user: "<user_instructions>be brief</user_instructions>\nRename the Host picker",
			want: "Rename the Host picker",
		},
		{
			name: "unpaired tag is dropped on its own",
			user: "<system-reminder>\nTidy the sidebar footer",
			want: "Tidy the sidebar footer",
		},
		{
			name: "front matter leads",
			user: "---\ntags:\n  - tui\n---\nDraw the program status dot",
			want: "Draw the program status dot",
		},
		{
			name: "pasted code block leads",
			user: "```\nfunc main() {}\n```\nWhy does this deadlock?",
			// Labels carry no trailing punctuation, exactly as a model title does.
			want: "Why does this deadlock",
		},
		{
			name: "json body leads",
			user: "{\"error\":\"boom\",\"path\":\"/work/a b\"}\nThe build breaks after the upgrade",
			want: "The build breaks after the upgrade",
		},
		{
			name: "slash command leads",
			user: "/compact\nKeep the terminal title stable",
			want: "Keep the terminal title stable",
		},
		{
			name: "list marker leads",
			user: "- Add the missing test",
			want: "Add the missing test",
		},
		{
			name: "heading marker leads",
			user: "### Name every host\nDetails below",
			want: "Name every host",
		},
		{
			name: "inline markup is dropped",
			user: "Fix the `reconnect` **flow** <b>now</b>",
			want: "Fix the reconnect flow now",
		},
		{
			name: "chinese request",
			user: "把侧栏标题改成程序自己的名字",
			want: "把侧栏标题改成程序自己的名字",
		},
		{
			name: "only the first line is the label",
			user: "Fix the reconnect flow\nThen check the roster",
			want: "Fix the reconnect flow",
		},
		{
			name: "punctuation is trimmed",
			user: "Fix the reconnect flow.",
			want: "Fix the reconnect flow",
		},
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			if got := LocalLabel(testCase.user); got != testCase.want {
				t.Fatalf("LocalLabel(%q) = %q, want %q", testCase.user, got, testCase.want)
			}
		})
	}
}

// Nothing worth reading means nothing at all: the caller keeps the Session's
// own rule rather than drawing an empty label.
func TestLocalLabelReturnsNothingWithoutWords(t *testing.T) {
	for _, user := range []string{
		"",
		"   ",
		"<environment_context></environment_context>",
		"```\nonly a code block\n```",
		"{\"only\":\"json\"}",
		"/compact",
		"---\ntags: [tui]\n---",
		"---",
		"???!",
	} {
		if got := LocalLabel(user); got != "" {
			t.Fatalf("LocalLabel(%q) = %q, want empty", user, got)
		}
	}
}

func TestLocalLabelStaysInsideTheRowBudget(t *testing.T) {
	long := strings.Repeat("reconnect ", 20)
	got := LocalLabel(long)
	if runes := len([]rune(got)); runes > localLabelLimit+1 {
		t.Fatalf("LocalLabel length = %d runes, want at most %d plus the ellipsis", runes, localLabelLimit)
	}
	if !strings.HasSuffix(got, "…") {
		t.Fatalf("clipped label = %q, want an ellipsis", got)
	}
}
