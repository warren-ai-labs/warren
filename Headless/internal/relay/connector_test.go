package relay

import (
	"strings"
	"testing"
	"time"
)

func TestHostEndpointAcceptsIPPortsAndPreservesRelayBasePath(t *testing.T) {
	tests := []struct {
		name string
		url  string
		want string
	}{
		{name: "ipv4", url: "http://192.0.2.10:8080", want: "ws://192.0.2.10:8080/v1/host/connect"},
		{name: "ipv6", url: "https://[2001:db8::10]:8443/relay/", want: "wss://[2001:db8::10]:8443/relay/v1/host/connect"},
		{name: "websocket", url: "ws://relay.example.test:9000", want: "ws://relay.example.test:9000/v1/host/connect"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			endpoint, err := hostEndpoint(test.url, "00000000-0000-4000-8000-000000000001", "Smoke Host")
			if err != nil {
				t.Fatal(err)
			}
			if !strings.HasPrefix(endpoint, test.want+"?") {
				t.Fatalf("endpoint = %q, want prefix %q", endpoint, test.want+"?")
			}
			if !strings.Contains(endpoint, "host_id=00000000-0000-4000-8000-000000000001") || !strings.Contains(endpoint, "version=2.0") || !strings.Contains(endpoint, "name=Smoke+Host") {
				t.Fatalf("endpoint query lost connector identity: %q", endpoint)
			}
		})
	}
}

func TestHostEndpointRejectsAmbiguousOrUnsafeURLs(t *testing.T) {
	for _, value := range []string{
		"relay.example.test",
		"ftp://relay.example.test",
		"https://user:password@relay.example.test",
		"https://relay.example.test/../private",
		"https://relay.example.test/%2e%2e/private",
		"https://relay.example.test#fragment",
	} {
		if endpoint, err := hostEndpoint(value, "00000000-0000-4000-8000-000000000001", ""); err == nil {
			t.Errorf("hostEndpoint(%q) accepted unsafe endpoint %q", value, endpoint)
		}
	}
}

func TestBackoffDelayIsBoundedAndJittered(t *testing.T) {
	for _, attempt := range []int{-1, 0, 1, 5, 10} {
		base := time.Second << min(max(attempt, 0), 5)
		minimum := time.Duration(float64(base) * 0.8)
		maximum := time.Duration(float64(base) * 1.2)
		value := BackoffDelay(attempt, func() float64 { return 0.5 })
		if value < minimum || value > maximum {
			t.Errorf("BackoffDelay(%d) = %s, want within [%s, %s]", attempt, value, minimum, maximum)
		}
	}
}

func max(left, right int) int {
	if left > right {
		return left
	}
	return right
}
