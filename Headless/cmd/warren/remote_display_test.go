package main

import "testing"

func TestDisplayedRemoteRelayNamesTheOfficialRelay(t *testing.T) {
	for _, test := range []struct {
		name   string
		object map[string]any
		want   string
	}{
		{"status on the official relay", map[string]any{"relayURL": "https://official.example", "relaySource": "default", "defaultRelayURL": "https://official.example"}, "official"},
		{"share on the official relay", map[string]any{"relayURL": "https://official.example", "relaySource": "default"}, "official"},
		{"status before it has started", map[string]any{"defaultRelayURL": "https://official.example"}, "official"},
		{"self-hosted status", map[string]any{"relayURL": "https://mine.example", "relaySource": "self-hosted", "defaultRelayURL": "https://official.example"}, "https://mine.example"},
		{"self-hosted share", map[string]any{"relayURL": "https://mine.example", "relaySource": "self-hosted"}, "https://mine.example"},
	} {
		if got := displayedRemoteRelay(test.object); got != test.want {
			t.Errorf("%s: displayed relay = %q, want %q", test.name, got, test.want)
		}
	}
}
