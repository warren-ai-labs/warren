package api

import (
	"crypto/sha256"
	"encoding/hex"
	"testing"
)

func TestNegotiateCapabilitiesKeepsHostOrderAndDropsUnknownValues(t *testing.T) {
	host := []string{"roster-delta", CapabilityAgentTimeline, CapabilityAgentTimeline, ""}
	client := []string{"unknown", CapabilityAgentTimeline, " roster-delta ", CapabilityAgentTimeline}
	got := NegotiateCapabilities(host, client)
	want := []string{"roster-delta", CapabilityAgentTimeline}
	if len(got) != len(want) {
		t.Fatalf("capability count = %v, want %v", got, want)
	}
	for index := range want {
		if got[index] != want[index] {
			t.Fatalf("capability %d = %q, want %q", index, got[index], want[index])
		}
	}
	if SupportsCapability(got, "missing") {
		t.Fatal("unknown capability was reported as supported")
	}
}

func TestAgentAttachmentChunkDigestValidatesLengthAndChecksum(t *testing.T) {
	data := []byte("chunk")
	digest := sha256.Sum256(data)
	hash := hex.EncodeToString(digest[:])
	if err := AgentAttachmentChunkDigest(data, len(data), hash); err != nil {
		t.Fatalf("valid chunk rejected: %v", err)
	}
	if err := AgentAttachmentChunkDigest(data, len(data)-1, hash); err == nil {
		t.Fatal("length mismatch was accepted")
	}
	if err := AgentAttachmentChunkDigest(data, len(data), "00"); err == nil {
		t.Fatal("checksum mismatch was accepted")
	}
	if err := AgentAttachmentChunkDigest(nil, 0, ""); err != nil {
		t.Fatalf("empty chunk rejected: %v", err)
	}
}
