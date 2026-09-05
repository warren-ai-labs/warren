package relay

import (
	"context"
	"errors"
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

func TestConnectorStateSnapshot(t *testing.T) {
	t.Parallel()
	connector, err := New(Config{URL: "wss://relay.invalid", HostID: "h", Secret: "s"})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	running, connected, currentState, lastError := connector.State()
	if running || connected || currentState != "" || lastError != "" {
		t.Fatalf("fresh connector has unexpected state: running=%v connected=%v state=%q err=%q", running, connected, currentState, lastError)
	}
	connector.recordError(errors.New("dial refused"))
	_, _, _, lastError = connector.State()
	if lastError != "dial refused" {
		t.Fatalf("recordError not surfaced: got %q", lastError)
	}
	connector.recordError(nil)
	_, _, _, lastError = connector.State()
	if lastError != "" {
		t.Fatalf("recordError(nil) did not clear: got %q", lastError)
	}
}

func TestConnectorStateCallback(t *testing.T) {
	t.Parallel()
	var observed []string
	connector, err := New(Config{
		URL:     "wss://relay.invalid",
		HostID:  "h",
		Secret:  "s",
		OnState: func(s string) { observed = append(observed, s) },
	})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	connector.state("connecting")
	connector.state("open")
	if len(observed) != 2 || observed[0] != "connecting" || observed[1] != "open" {
		t.Fatalf("OnState invocations: %v", observed)
	}
	_, _, currentState, _ := connector.State()
	if currentState != "open" {
		t.Fatalf("last state not retained: %q", currentState)
	}
}

func TestCloseStreamsOnlyClosesTheDisconnectedEpoch(t *testing.T) {
	oldContext, oldCancel := context.WithCancel(context.Background())
	currentContext, currentCancel := context.WithCancel(context.Background())
	defer currentCancel()
	old := newStream(streamOpen{Class: "http"}, 1, oldContext, oldCancel)
	current := newStream(streamOpen{Class: "http"}, 2, currentContext, currentCancel)
	idOld := connectionID{1}
	idCurrent := connectionID{2}
	connector := &Connector{
		streams: map[connectionID]*stream{idOld: old, idCurrent: current},
		usedIDs: map[connectionID]uint64{idOld: 1, idCurrent: 2},
	}

	connector.closeStreams(1)

	connector.mu.Lock()
	_, oldPresent := connector.streams[idOld]
	_, currentPresent := connector.streams[idCurrent]
	connector.mu.Unlock()
	if oldPresent || !currentPresent {
		t.Fatalf("epoch fence removed wrong streams: old=%v current=%v", oldPresent, currentPresent)
	}
	select {
	case <-old.ctx.Done():
	default:
		t.Fatal("old stream context was not canceled")
	}
}

func TestSendDataRejectsStreamFromPreviousEpoch(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	id := connectionID{3}
	connector := &Connector{
		connectionEpoch: 2,
		streams:         map[connectionID]*stream{id: newStream(streamOpen{Class: "http"}, 1, ctx, cancel)},
	}
	if err := connector.sendData(id, []byte("stale")); err == nil || !strings.Contains(err.Error(), "stream closed") {
		t.Fatalf("sendData accepted stale stream: %v", err)
	}
}

func TestConnectionWriterReservesControlQueue(t *testing.T) {
	writer := newConnectionWriter(nil, 1)
	for index := 0; index < connectorDataQueueCapacity; index++ {
		if err := writer.enqueue(queuedWrite{done: make(chan error, 1)}, false); err != nil {
			t.Fatalf("data enqueue %d: %v", index, err)
		}
	}
	if err := writer.enqueue(queuedWrite{done: make(chan error, 1)}, false); err == nil {
		t.Fatal("data queue accepted an item beyond its bound")
	}
	if err := writer.enqueue(queuedWrite{done: make(chan error, 1)}, true); err != nil {
		t.Fatalf("control queue was starved by data: %v", err)
	}
	writer.stopWith(nil)
}

func TestControlStreamFramesDoNotWaitForBodyCredit(t *testing.T) {
	streamValue := newStream(streamOpen{Class: "control"}, 1, context.Background(), func() {})
	for _, kind := range []byte{frameText, frameBinary} {
		if streamFrameNeedsCredit(streamValue, kind) {
			t.Errorf("control frame kind %d was classified as body traffic", kind)
		}
	}
	if !streamFrameNeedsCredit(streamValue, frameData) {
		t.Fatal("control DATA frame lost flow control")
	}
	httpStream := newStream(streamOpen{Class: "http"}, 1, context.Background(), func() {})
	if !streamFrameNeedsCredit(httpStream, frameText) {
		t.Fatal("HTTP frame bypassed flow control")
	}
}

func TestStreamRejectsWindowOverCredit(t *testing.T) {
	streamValue := newStream(streamOpen{Class: "http"}, 1, context.Background(), func() {})
	streamValue.windowMu.Lock()
	streamValue.window = initialWindow - 8
	streamValue.windowMu.Unlock()
	if !streamValue.grantCredit(8) {
		t.Fatal("valid window credit was rejected")
	}
	if streamValue.grantCredit(1) {
		t.Fatal("window over-credit was accepted")
	}
	streamValue.windowMu.Lock()
	window := streamValue.window
	streamValue.windowMu.Unlock()
	if window != initialWindow {
		t.Fatalf("over-credit changed window to %d, want %d", window, initialWindow)
	}
	if !streamValue.grantCredit(0) {
		t.Fatal("zero window credit should be a no-op")
	}
}

func TestPublicRouteStreamContextIsScopedToMarkedUpgrade(t *testing.T) {
	plain, plainCancel := streamContext(streamOpen{Class: "upgrade"})
	defer plainCancel()
	if IsPublicRoute(plain) {
		t.Fatal("unmarked stream inherited public route context")
	}

	marked, markedCancel := streamContext(streamOpen{Class: "upgrade", PublicRoute: true})
	defer markedCancel()
	if !IsPublicRoute(marked) {
		t.Fatal("marked public stream did not carry route context")
	}

	if IsPublicRoute(context.Background()) {
		t.Fatal("background context unexpectedly carried public route marker")
	}
}

func TestPublicRouteMetadataRejectsNonUpgradeStream(t *testing.T) {
	connector := &Connector{}
	id := connectionID{1}
	err := connector.dispatch(frame{Kind: frameOpen, ID: id, Payload: mustJSON(streamOpen{
		Class:       "http",
		Version:     version,
		PublicRoute: true,
		Token:       "capability",
	})})
	if err == nil || !strings.Contains(err.Error(), "websocket upgrade") {
		t.Fatalf("public HTTP stream was not rejected: %v", err)
	}
}
