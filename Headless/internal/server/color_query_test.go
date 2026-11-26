package server

import (
	"context"
	"testing"

	"github.com/abcdlsj/ghostline"
	"github.com/abcdlsj/warren/Headless/internal/output"
)

func TestWarrenColorQuery(t *testing.T) {
	tests := []struct {
		name string
		kind ghostline.ColorQueryKind
		want string
	}{
		{name: "foreground", kind: ghostline.ColorQueryForeground, want: warrenTerminalForeground},
		{name: "background", kind: ghostline.ColorQueryBackground, want: warrenTerminalBackground},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, ok := WarrenColorQuery(test.kind)
			if !ok || got != test.want {
				t.Fatalf("WarrenColorQuery(%d) = %q, %t; want %q, true", test.kind, got, ok, test.want)
			}
		})
	}
	if got, ok := WarrenColorQuery(0); ok || got != "" {
		t.Fatalf("WarrenColorQuery(0) = %q, %t; want empty, false", got, ok)
	}
}

func TestServiceQueryResponderUsesColorQuery(t *testing.T) {
	service := &Service{
		ColorQuery: func(kind ghostline.ColorQueryKind) (string, bool) {
			if kind == ghostline.ColorQueryBackground {
				return "#151110", true
			}
			return "", false
		},
	}
	responder := service.newQueryResponder()
	replies := responder.Feed([]byte("\x1b]11;?\x1b\\"))
	if len(replies) != 1 || string(replies[0]) != "\x1b]11;rgb:1515/1111/1010\x1b\\" {
		t.Fatalf("service responder replies = %q; want Warren background reply", replies)
	}
}

func TestServiceDoesNotAnswerColorQueryWhenSessionAttached(t *testing.T) {
	runtime := &memoryRuntime{sessions: map[string][]byte{"runtime": nil}}
	service := &Service{
		Runtime: runtime,
		ColorQuery: func(kind ghostline.ColorQueryKind) (string, bool) {
			if kind == ghostline.ColorQueryBackground {
				return "#151110", true
			}
			return "", false
		},
		outputs: map[string]*outputSession{
			"session": {
				sessionID:   "session",
				runtimeName: "runtime",
				ring:        output.NewRing(0, 1, 1024, 0),
				responder:   nil,
			},
		},
		peers: map[string]map[*wsPeer]struct{}{
			"session": {
				{outbound: make(chan outboundMessage, 1), closed: make(chan struct{})}: {},
			},
		},
	}
	service.outputs["session"].responder = service.newQueryResponder()

	service.recordOutput("session", []byte("\x1b]11;?\x1b\\"))

	got, err := runtime.Capture(context.Background(), "runtime")
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 0 {
		t.Fatalf("attached session runtime input = %q; want no server reply", got)
	}
}

func TestServiceAnswersSyncOutputDECRQMAsResetWhenDetached(t *testing.T) {
	runtime := &memoryRuntime{sessions: map[string][]byte{"runtime": nil}}
	service := &Service{
		Runtime: runtime,
		outputs: map[string]*outputSession{
			"session": {
				sessionID:   "session",
				runtimeName: "runtime",
				ring:        output.NewRing(0, 1, 1024, 0),
			},
		},
		peers: map[string]map[*wsPeer]struct{}{},
	}
	service.outputs["session"].responder = service.newQueryResponder()

	service.recordOutput("session", []byte("\x1b[?2026$p\x1b[?2027$p"))

	got, err := runtime.Capture(context.Background(), "runtime")
	if err != nil {
		t.Fatal(err)
	}
	want := "\x1b[?2026;2$y\x1b[?2027;2$y"
	if string(got) != want {
		t.Fatalf("detached session DECRQM reply = %q; want %q", got, want)
	}
}
