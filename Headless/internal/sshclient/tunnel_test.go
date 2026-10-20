package sshclient

import (
	"errors"
	"fmt"
	"io"
	"net"
	"reflect"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"
	"golang.org/x/crypto/ssh/knownhosts"
)

type testPublicKey struct{ typ string }

func (key testPublicKey) Type() string                        { return key.typ }
func (key testPublicKey) Marshal() []byte                     { return []byte(key.typ) }
func (key testPublicKey) Verify([]byte, *ssh.Signature) error { return nil }

func TestLastNonEmptyLine(t *testing.T) {
	if got := lastNonEmptyLine("warning\n0123456789abcdef0123456789abcdef\n"); got != "0123456789abcdef0123456789abcdef" {
		t.Fatalf("unexpected token: %q", got)
	}
}

func TestValidateToken(t *testing.T) {
	if !validateToken("short") {
		t.Fatal("expected opaque non-empty token")
	}
	if !validateToken("0123456789abcdef0123456789abcdef") {
		t.Fatal("expected valid token")
	}
	if !validateToken("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef") {
		t.Fatal("expected valid 64-character hex token")
	}
	if !validateToken("0123456789abcdef0123456789abcdef0123456789a") {
		t.Fatal("expected valid URL-safe base64 token")
	}
	for _, value := range []string{"", "token with spaces", "token\nwith-newline", string([]byte{'t', 0, 'k'})} {
		if validateToken(value) {
			t.Fatalf("expected invalid token: %q", value)
		}
	}
}

func TestSplitAddressRejectsInvalidPorts(t *testing.T) {
	if host, port, err := splitAddress("127.0.0.1:8789"); err != nil || host != "127.0.0.1" || port != "8789" {
		t.Fatalf("splitAddress returned %q, %q, %v", host, port, err)
	}
	for _, address := range []string{"127.0.0.1:0", "127.0.0.1:65536", "127.0.0.1:$(id)", "127.0.0.1"} {
		if _, _, err := splitAddress(address); err == nil {
			t.Fatalf("splitAddress(%q) unexpectedly succeeded", address)
		}
	}
}

func TestValidateLoopbackAddress(t *testing.T) {
	for _, address := range []string{"127.0.0.1:0", "127.42.0.9:8791", "[::1]:8790"} {
		if err := validateLoopbackAddress(address); err != nil {
			t.Errorf("validateLoopbackAddress(%q) = %v", address, err)
		}
	}
	for _, address := range []string{"0.0.0.0:8790", "192.0.2.1:8790", "warren.local:8790", "localhost:8791"} {
		if err := validateLoopbackAddress(address); err == nil {
			t.Errorf("validateLoopbackAddress(%q) unexpectedly succeeded", address)
		}
	}
}

func TestProxyCopiesBothDirections(t *testing.T) {
	left, right := net.Pipe()
	done := make(chan struct{})
	go func() {
		proxy(left, right)
		close(done)
	}()
	defer left.Close()
	defer right.Close()

	if _, err := left.Write([]byte("to-right")); err != nil {
		t.Fatal(err)
	}
	buffer := make([]byte, len("to-right"))
	if _, err := right.Read(buffer); err != nil {
		t.Fatal(err)
	}
	if string(buffer) != "to-right" {
		t.Fatalf("right received %q", buffer)
	}
	if _, err := right.Write([]byte("to-left")); err != nil {
		t.Fatal(err)
	}
	buffer = make([]byte, len("to-left"))
	if _, err := left.Read(buffer); err != nil {
		t.Fatal(err)
	}
	if string(buffer) != "to-left" {
		t.Fatalf("left received %q", buffer)
	}
	_ = left.Close()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("proxy did not stop after one side closed")
	}
}

func TestKnownHostKeyAlgorithmCandidates(t *testing.T) {
	err := fmt.Errorf("ssh: handshake failed: %w", &knownhosts.KeyError{Want: []knownhosts.KnownKey{
		{Key: testPublicKey{typ: ssh.KeyAlgoED25519}},
		{Key: testPublicKey{typ: ssh.KeyAlgoRSA}},
		{Key: testPublicKey{typ: ssh.KeyAlgoED25519}},
	}})
	got := knownHostKeyAlgorithmCandidates(err)
	want := [][]string{
		{ssh.KeyAlgoED25519, ssh.CertAlgoED25519v01},
		{ssh.KeyAlgoRSASHA512, ssh.KeyAlgoRSASHA256, ssh.KeyAlgoRSA, ssh.CertAlgoRSASHA512v01, ssh.CertAlgoRSASHA256v01, ssh.CertAlgoRSAv01},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("known host algorithms = %#v, want %#v", got, want)
	}
	if got := knownHostKeyAlgorithmCandidates(errors.New("not a known host error")); got != nil {
		t.Fatalf("unexpected candidates for unrelated error: %#v", got)
	}
}

type keepaliveSender struct {
	block chan struct{}
	err   error
	sent  chan struct{}
}

func (sender *keepaliveSender) SendRequest(string, bool, []byte) (bool, []byte, error) {
	if sender.sent != nil {
		select {
		case sender.sent <- struct{}{}:
		default:
		}
	}
	if sender.block != nil {
		<-sender.block
	}
	return false, nil, sender.err
}

func TestKeepAliveGivesUpAfterConsecutiveSilentProbes(t *testing.T) {
	sender := &keepaliveSender{block: make(chan struct{})}
	defer close(sender.block)
	result := make(chan bool, 1)
	go func() { result <- keepAlive(make(chan struct{}), sender, 10*time.Millisecond, 3) }()
	select {
	case alive := <-result:
		if alive {
			t.Fatal("keepAlive reported a silent connection as alive")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("keepAlive never gave up on a silent connection")
	}
}

func TestKeepAliveTreatsARejectedRequestAsAlive(t *testing.T) {
	sender := &keepaliveSender{sent: make(chan struct{}, 1)}
	done := make(chan struct{})
	result := make(chan bool, 1)
	go func() { result <- keepAlive(done, sender, 5*time.Millisecond, 2) }()
	for range 5 {
		select {
		case <-sender.sent:
		case <-time.After(2 * time.Second):
			t.Fatal("keepAlive stopped probing")
		}
	}
	close(done)
	if alive := <-result; !alive {
		t.Fatal("a replying connection was reported dead")
	}
}

func TestKeepAliveStopsOnTransportError(t *testing.T) {
	sender := &keepaliveSender{err: io.EOF}
	if keepAlive(make(chan struct{}), sender, 5*time.Millisecond, 3) {
		t.Fatal("a closed connection was reported alive")
	}
}
