package relay

import (
	"bytes"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

// The Host uplink carries every byte a remote client reads and is usually the
// narrowest link in the path, so the dialer must actually offer
// permessage-deflate rather than leaving it to the Relay to ask for.
func TestRelayDialerNegotiatesCompression(t *testing.T) {
	t.Parallel()
	if !relayDialer.EnableCompression {
		t.Fatal("relay dialer does not offer compression")
	}
	var offered string
	upgrader := websocket.Upgrader{EnableCompression: true}
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		offered = request.Header.Get("Sec-WebSocket-Extensions")
		connection, err := upgrader.Upgrade(response, request, nil)
		if err != nil {
			return
		}
		defer connection.Close()
		if _, _, err := connection.ReadMessage(); err != nil {
			return
		}
	}))
	defer server.Close()

	endpoint := "ws" + strings.TrimPrefix(server.URL, "http")
	connection, response, err := relayDialer.Dial(endpoint, nil)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer connection.Close()
	if !strings.Contains(offered, "permessage-deflate") {
		t.Fatalf("dialer did not offer permessage-deflate: %q", offered)
	}
	if accepted := response.Header.Get("Sec-WebSocket-Extensions"); !strings.Contains(accepted, "permessage-deflate") {
		t.Fatalf("server did not accept compression: %q", accepted)
	}
	if err := connection.WriteMessage(websocket.BinaryMessage, []byte("frame")); err != nil {
		t.Fatalf("write over a compressed connection: %v", err)
	}
}

// countingConn records how many bytes actually reach the network, which is the
// only way to tell a negotiated-but-unused extension from a working one.
type countingConn struct {
	net.Conn
	mu      sync.Mutex
	written int
}

func (connection *countingConn) Write(data []byte) (int, error) {
	n, err := connection.Conn.Write(data)
	connection.mu.Lock()
	connection.written += n
	connection.mu.Unlock()
	return n, err
}

func (connection *countingConn) bytes() int {
	connection.mu.Lock()
	defer connection.mu.Unlock()
	return connection.written
}

// Compression is decided per frame, so the toggle runs mid-stream on a live
// connection. Verify both halves of that decision on the wire: a burst worth
// compressing shrinks, a keystroke-sized frame is not inflated by deflate's own
// per-message overhead, and every payload still arrives byte-exact.
func TestPerFrameCompressionShrinksBurstsWithoutInflatingKeystrokes(t *testing.T) {
	t.Parallel()
	upgrader := websocket.Upgrader{EnableCompression: true}
	received := make(chan []byte, 16)
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		connection, err := upgrader.Upgrade(response, request, nil)
		if err != nil {
			return
		}
		defer connection.Close()
		for {
			_, payload, err := connection.ReadMessage()
			if err != nil {
				return
			}
			received <- append([]byte(nil), payload...)
		}
	}))
	defer server.Close()

	var counter *countingConn
	dialer := *relayDialer
	dialer.NetDial = func(network, address string) (net.Conn, error) {
		raw, err := net.Dial(network, address)
		if err != nil {
			return nil, err
		}
		counter = &countingConn{Conn: raw}
		return counter, nil
	}
	endpoint := "ws" + strings.TrimPrefix(server.URL, "http")
	connection, _, err := dialer.Dial(endpoint, nil)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer connection.Close()

	send := func(payload []byte) int {
		before := counter.bytes()
		connection.EnableWriteCompression(len(payload) >= compressionThreshold)
		if err := connection.WriteMessage(websocket.BinaryMessage, payload); err != nil {
			t.Fatalf("write %d bytes: %v", len(payload), err)
		}
		select {
		case echoed := <-received:
			if !bytes.Equal(echoed, payload) {
				t.Fatalf("payload of %d bytes did not survive the round trip", len(payload))
			}
		case <-time.After(5 * time.Second):
			t.Fatalf("payload of %d bytes was never received", len(payload))
		}
		return counter.bytes() - before
	}

	// Terminal output repeats heavily, so a burst should cost a fraction of its
	// length once deflated.
	burst := []byte(strings.Repeat("warren relay output line\r\n", 2048))
	burstWire := send(burst)
	if burstWire >= len(burst)/4 {
		t.Fatalf("burst of %d bytes used %d wire bytes; compression is not being applied", len(burst), burstWire)
	}

	// A keystroke must not pay deflate's per-message floor. Interleave it after a
	// compressed frame so the toggle is exercised in both directions.
	keystroke := []byte("x")
	keystrokeWire := send(keystroke)
	if keystrokeWire > 16 {
		t.Fatalf("keystroke used %d wire bytes; small frames are being compressed", keystrokeWire)
	}
	if wire := send(burst); wire >= len(burst)/4 {
		t.Fatalf("second burst used %d wire bytes; the toggle did not re-enable compression", wire)
	}
	if wire := send(keystroke); wire > 16 {
		t.Fatalf("second keystroke used %d wire bytes", wire)
	}
}
