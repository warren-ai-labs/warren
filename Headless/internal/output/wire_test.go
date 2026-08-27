package output

import (
	"bytes"
	"testing"
)

func TestOutputEnvelopeRoundTrip(t *testing.T) {
	payload := []byte("\x1b[31mred\r\n")
	encoded, err := EncodeOutput("session-1", 3, 42, payload)
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := DecodeOutput(encoded)
	if err != nil {
		t.Fatal(err)
	}
	if decoded.SessionID != "session-1" || decoded.Epoch != 3 || decoded.Sequence != 42 {
		t.Fatalf("decoded header = %#v", decoded)
	}
	if !bytes.Equal(decoded.Payload, payload) {
		t.Fatalf("payload mismatch: %q", decoded.Payload)
	}
}

func TestAtomicStateEnvelopeRoundTrip(t *testing.T) {
	payload := append([]byte("GHOSTSNP"), bytes.Repeat([]byte{0x7f}, 1024)...)
	encoded, err := EncodeAtomicState(
		"session-atomic",
		9,
		512,
		"ghostty-vt-snapshot-v1",
		payload,
	)
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := DecodeAtomicState(encoded)
	if err != nil {
		t.Fatal(err)
	}
	if decoded.SessionID != "session-atomic" || decoded.Epoch != 9 || decoded.Sequence != 512 {
		t.Fatalf("decoded header = %#v", decoded)
	}
	if decoded.Format != "ghostty-vt-snapshot-v1" {
		t.Fatalf("decoded format = %q", decoded.Format)
	}
	if !bytes.Equal(decoded.Payload, payload) {
		t.Fatal("atomic state payload changed")
	}
	if _, err := DecodeOutput(encoded); err == nil {
		t.Fatal("atomic state was accepted as terminal output")
	}
}

func TestAtomicStateRequiresFormat(t *testing.T) {
	if _, err := EncodeAtomicState("session", 1, 2, "", []byte("snapshot")); err == nil {
		t.Fatal("atomic state without a format was accepted")
	}
}

func TestBinaryPayloadLimitsAlignAcrossKinds(t *testing.T) {
	outputAtLimit := make([]byte, MaxPayload)
	if _, err := EncodeOutput("session", 1, 2, outputAtLimit); err != nil {
		t.Fatalf("output at 8 MiB limit: %v", err)
	}
	if _, err := EncodeOutput("session", 1, 2, append(outputAtLimit, 0)); err == nil {
		t.Fatal("output above 8 MiB limit was accepted")
	}

	// Atomic snapshots have their own 64 MiB budget. Exercise both the first
	// byte above the ordinary output limit and the exact atomic boundary.
	atomicAboveOutput := make([]byte, MaxPayload+1)
	if _, err := EncodeAtomicState("session", 1, 2, "ghostline-vt-replay-v1", atomicAboveOutput); err != nil {
		t.Fatalf("8-64 MiB atomic state: %v", err)
	}
	atomicAtLimit := make([]byte, MaxAtomicStatePayload)
	if _, err := EncodeAtomicState("session", 1, 2, "ghostline-vt-replay-v1", atomicAtLimit); err != nil {
		t.Fatalf("atomic state at 64 MiB limit: %v", err)
	}
	if _, err := EncodeAtomicState("session", 1, 2, "ghostline-vt-replay-v1", append(atomicAtLimit, 0)); err == nil {
		t.Fatal("atomic state above 64 MiB limit was accepted")
	}
}

func TestBinaryHeadersValidateLengthDirectionAndFormat(t *testing.T) {
	payload := []byte("state")
	encoded, err := EncodeAtomicState("session", 3, 9, "ghostline-vt-replay-v1", payload)
	if err != nil {
		t.Fatal(err)
	}
	// The envelope length and the JSON header length are checked separately.
	badHeader := bytes.Replace(encoded, []byte(`"payloadLength":5`), []byte(`"payloadLength":6`), 1)
	if _, err := DecodeAtomicState(badHeader); err == nil {
		t.Fatal("atomic header/payload length mismatch was accepted")
	}

	wrongDirection, err := encodeEnvelope(DirectionClientToHost, KindAtomicState, atomicStateHeader{
		SessionID: "session", Epoch: 3, Sequence: 9, Format: "ghostline-vt-replay-v1", PayloadLength: len(payload),
	}, payload)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := DecodeAtomicState(wrongDirection); err == nil {
		t.Fatal("atomic state with client-to-host direction was accepted")
	}

	badFormat, err := encodeEnvelope(DirectionHostToClient, KindAtomicState, atomicStateHeader{
		SessionID: "session", Epoch: 3, Sequence: 9, Format: "", PayloadLength: len(payload),
	}, payload)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := DecodeAtomicState(badFormat); err == nil {
		t.Fatal("atomic state with an empty format was accepted")
	}
}

func TestOutputPreservesAnsiOscCjkAndEmoji(t *testing.T) {
	payload := []byte("\x1b]0;Warren 终端 🚀\x07\x1b[38;5;196m你好，世界 \xf0\x9f\x8e\x89\x1b[2J\x1b[H")
	encoded, err := EncodeOutput("session-1", 4, 128, payload)
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := DecodeOutput(encoded)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(decoded.Payload, payload) {
		t.Fatalf("multibyte payload changed: %q", decoded.Payload)
	}
	if decoded.Sequence != 128 || decoded.Epoch != 4 {
		t.Fatalf("header = %#v", decoded)
	}
}

func TestInputEnvelopeRoundTrip(t *testing.T) {
	payload := []byte("ls\r")
	encoded, err := EncodeInput(InputMetadata{
		Version: "1.0", SessionID: "s", AttachmentID: "a", Sequence: 7,
	}, payload)
	if err != nil {
		t.Fatal(err)
	}
	metadata, decoded, err := DecodeInput(encoded)
	if err != nil {
		t.Fatal(err)
	}
	if metadata.SessionID != "s" || metadata.AttachmentID != "a" || metadata.Sequence != 7 {
		t.Fatalf("metadata = %#v", metadata)
	}
	if !bytes.Equal(decoded, payload) {
		t.Fatalf("payload mismatch: %q", decoded)
	}
}

func TestWireRejectsCorruptFrames(t *testing.T) {
	if _, err := DecodeOutput([]byte{1, 2, 3}); err == nil {
		t.Fatal("truncated frame accepted")
	}
	payload := []byte("x")
	encoded, _ := EncodeOutput("s", 0, 0, payload)
	encoded = append(encoded, 0)
	if _, err := DecodeOutput(encoded); err == nil {
		t.Fatal("trailing byte accepted")
	}
	encoded, _ = EncodeOutput("s", 0, 0, payload)
	encoded[5] = DirectionClientToHost
	if _, err := DecodeOutput(encoded); err == nil {
		t.Fatal("wrong direction accepted")
	}
}

func TestSplitPayloadBoundsChunks(t *testing.T) {
	payload := make([]byte, MaxPayload+7)
	chunks := SplitPayload(payload)
	if len(chunks) != 2 {
		t.Fatalf("chunks = %d, want 2", len(chunks))
	}
	if len(chunks[0]) != MaxPayload || len(chunks[1]) != 7 {
		t.Fatalf("chunk sizes = %d, %d", len(chunks[0]), len(chunks[1]))
	}
}
