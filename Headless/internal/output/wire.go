package output

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"fmt"

	"github.com/abcdlsj/warren/Headless/internal/protocol"
)

// Binary envelope wire format. This is intentionally the same DENB envelope
// used by the Swift transport: magic "DENB", version 1, direction byte, kind
// byte, header length (u32 BE), payload length (u32 BE), JSON header, payload.
//
// The constants live in protocol/warren.schema.json and are generated into
// internal/protocol/wire.go. The aliases below preserve the existing
// output.* API for callers in this module.
var (
	BinaryMagic = protocol.BinaryMagic
	Version     = protocol.BinaryWireVersion
)

const (
	DirectionClientToHost = protocol.DirectionClientToHost
	DirectionHostToClient = protocol.DirectionHostToClient

	KindInput  = protocol.KindInput
	KindOutput = protocol.KindOutput
	// KindAtomicState carries one opaque terminal-emulator snapshot. It is a
	// distinct kind so clients can never feed snapshot bytes through their VT
	// output parser by mistake.
	KindAtomicState = protocol.KindAtomicState

	MaxHeader             = protocol.MaxHeader
	MaxPayload            = protocol.MaxPayload
	MaxAtomicStatePayload = protocol.MaxAtomicStatePayload
)

var binaryPrefixLength = len(BinaryMagic) + 1 + 1 + 1 + 4 + 4

type outputHeader struct {
	SessionID     string `json:"sessionID"`
	Epoch         uint64 `json:"epoch"`
	Sequence      uint64 `json:"sequence"`
	PayloadLength int    `json:"payloadLength"`
}

type inputHeader struct {
	Version       string `json:"version"`
	SessionID     string `json:"sessionID"`
	AttachmentID  string `json:"attachmentID"`
	PayloadLength int    `json:"payloadLength"`
	Sequence      uint64 `json:"sequence,omitempty"`
}

type atomicStateHeader struct {
	SessionID     string `json:"sessionID"`
	Epoch         uint64 `json:"epoch"`
	Sequence      uint64 `json:"sequence"`
	Format        string `json:"format"`
	PayloadLength int    `json:"payloadLength"`
}

type InputMetadata struct {
	Version       string
	SessionID     string
	AttachmentID  string
	PayloadLength int
	Sequence      uint64
}

func EncodeOutput(sessionID string, epoch, sequence uint64, payload []byte) ([]byte, error) {
	return encodeEnvelope(DirectionHostToClient, KindOutput, outputHeader{
		SessionID:     sessionID,
		Epoch:         epoch,
		Sequence:      sequence,
		PayloadLength: len(payload),
	}, payload)
}

func EncodeAtomicState(sessionID string, epoch, sequence uint64, format string, payload []byte) ([]byte, error) {
	if format == "" {
		return nil, fmt.Errorf("atomic state format is required")
	}
	return encodeEnvelope(DirectionHostToClient, KindAtomicState, atomicStateHeader{
		SessionID:     sessionID,
		Epoch:         epoch,
		Sequence:      sequence,
		Format:        format,
		PayloadLength: len(payload),
	}, payload)
}

func EncodeInput(metadata InputMetadata, payload []byte) ([]byte, error) {
	if metadata.Version == "" {
		metadata.Version = protocol.LogicalVersion
	}
	return encodeEnvelope(DirectionClientToHost, KindInput, inputHeader{
		Version:       metadata.Version,
		SessionID:     metadata.SessionID,
		AttachmentID:  metadata.AttachmentID,
		PayloadLength: len(payload),
		Sequence:      metadata.Sequence,
	}, payload)
}

func encodeEnvelope(direction, kind byte, header any, payload []byte) ([]byte, error) {
	maxPayload := MaxPayload
	if kind == KindAtomicState {
		maxPayload = MaxAtomicStatePayload
	}
	if len(payload) > maxPayload {
		return nil, fmt.Errorf("binary payload too large: %d > %d", len(payload), maxPayload)
	}
	headerBytes, err := json.Marshal(header)
	if err != nil {
		return nil, fmt.Errorf("encode binary header: %w", err)
	}
	if len(headerBytes) > MaxHeader {
		return nil, fmt.Errorf("binary header too large: %d > %d", len(headerBytes), MaxHeader)
	}
	result := make([]byte, 0, binaryPrefixLength+len(headerBytes)+len(payload))
	result = append(result, BinaryMagic...)
	result = append(result, Version, direction, kind)
	var length [4]byte
	binary.BigEndian.PutUint32(length[:], uint32(len(headerBytes)))
	result = append(result, length[:]...)
	binary.BigEndian.PutUint32(length[:], uint32(len(payload)))
	result = append(result, length[:]...)
	result = append(result, headerBytes...)
	result = append(result, payload...)
	return result, nil
}

type DecodedFrame struct {
	SessionID string
	Epoch     uint64
	Sequence  uint64
	Payload   []byte
}

type DecodedAtomicState struct {
	SessionID string
	Epoch     uint64
	Sequence  uint64
	Format    string
	Payload   []byte
}

// DecodeOutput parses one Host-to-Client output envelope. The returned
// payload is a copy, so the input buffer can be reused.
func DecodeOutput(data []byte) (DecodedFrame, error) {
	direction, kind, headerBytes, payload, err := parseEnvelope(data)
	if err != nil {
		return DecodedFrame{}, err
	}
	if direction != DirectionHostToClient || kind != KindOutput {
		return DecodedFrame{}, fmt.Errorf("not a host-to-client output frame")
	}
	var header outputHeader
	if err := json.Unmarshal(headerBytes, &header); err != nil {
		return DecodedFrame{}, fmt.Errorf("decode output header: %w", err)
	}
	if header.PayloadLength != len(payload) {
		return DecodedFrame{}, fmt.Errorf("output payload length mismatch: header=%d actual=%d", header.PayloadLength, len(payload))
	}
	return DecodedFrame{
		SessionID: header.SessionID,
		Epoch:     header.Epoch,
		Sequence:  header.Sequence,
		Payload:   append([]byte(nil), payload...),
	}, nil
}

func DecodeAtomicState(data []byte) (DecodedAtomicState, error) {
	direction, kind, headerBytes, payload, err := parseEnvelope(data)
	if err != nil {
		return DecodedAtomicState{}, err
	}
	if direction != DirectionHostToClient || kind != KindAtomicState {
		return DecodedAtomicState{}, fmt.Errorf("not a host-to-client atomic state frame")
	}
	var header atomicStateHeader
	if err := json.Unmarshal(headerBytes, &header); err != nil {
		return DecodedAtomicState{}, fmt.Errorf("decode atomic state header: %w", err)
	}
	if header.Format == "" {
		return DecodedAtomicState{}, fmt.Errorf("atomic state format is required")
	}
	if header.PayloadLength != len(payload) {
		return DecodedAtomicState{}, fmt.Errorf("atomic state payload length mismatch: header=%d actual=%d", header.PayloadLength, len(payload))
	}
	return DecodedAtomicState{
		SessionID: header.SessionID,
		Epoch:     header.Epoch,
		Sequence:  header.Sequence,
		Format:    header.Format,
		Payload:   append([]byte(nil), payload...),
	}, nil
}

func DecodeInput(data []byte) (InputMetadata, []byte, error) {
	direction, kind, headerBytes, payload, err := parseEnvelope(data)
	if err != nil {
		return InputMetadata{}, nil, err
	}
	if direction != DirectionClientToHost || kind != KindInput {
		return InputMetadata{}, nil, fmt.Errorf("not a client-to-host input frame")
	}
	var header inputHeader
	if err := json.Unmarshal(headerBytes, &header); err != nil {
		return InputMetadata{}, nil, fmt.Errorf("decode input header: %w", err)
	}
	if header.PayloadLength != len(payload) {
		return InputMetadata{}, nil, fmt.Errorf("input payload length mismatch: header=%d actual=%d", header.PayloadLength, len(payload))
	}
	return InputMetadata{
		Version:       header.Version,
		SessionID:     header.SessionID,
		AttachmentID:  header.AttachmentID,
		PayloadLength: header.PayloadLength,
		Sequence:      header.Sequence,
	}, append([]byte(nil), payload...), nil
}

func parseEnvelope(data []byte) (direction, kind byte, headerBytes, payload []byte, err error) {
	if len(data) < binaryPrefixLength {
		return 0, 0, nil, nil, fmt.Errorf("truncated binary envelope")
	}
	if !bytes.Equal(data[:len(BinaryMagic)], BinaryMagic) {
		return 0, 0, nil, nil, fmt.Errorf("invalid binary magic")
	}
	offset := len(BinaryMagic)
	if data[offset] != Version {
		return 0, 0, nil, nil, fmt.Errorf("unsupported binary version %d", data[offset])
	}
	direction = data[offset+1]
	kind = data[offset+2]
	if (direction == DirectionClientToHost && kind != KindInput) ||
		(direction == DirectionHostToClient && kind != KindOutput && kind != KindAtomicState) {
		return 0, 0, nil, nil, fmt.Errorf("binary kind/direction mismatch")
	}
	headerLength := int(binary.BigEndian.Uint32(data[offset+3 : offset+7]))
	payloadLength := int(binary.BigEndian.Uint32(data[offset+7 : offset+11]))
	if headerLength > MaxHeader {
		return 0, 0, nil, nil, fmt.Errorf("binary header too large: %d", headerLength)
	}
	maxPayload := MaxPayload
	if kind == KindAtomicState {
		maxPayload = MaxAtomicStatePayload
	}
	if payloadLength > maxPayload {
		return 0, 0, nil, nil, fmt.Errorf("binary payload too large: %d", payloadLength)
	}
	payloadOffset := offset + 11
	expected := payloadOffset + headerLength + payloadLength
	if len(data) != expected {
		return 0, 0, nil, nil, fmt.Errorf("binary envelope length mismatch: have=%d want=%d", len(data), expected)
	}
	return direction, kind, data[payloadOffset : payloadOffset+headerLength], data[payloadOffset+headerLength : expected], nil
}

// SplitPayload splits one logical payload into MaxPayload-sized chunks so a
// large checkpoint replay can be sequenced into valid frames.
func SplitPayload(payload []byte) [][]byte {
	if len(payload) <= MaxPayload {
		return [][]byte{payload}
	}
	chunks := make([][]byte, 0, (len(payload)+MaxPayload-1)/MaxPayload)
	for len(payload) > MaxPayload {
		chunks = append(chunks, payload[:MaxPayload])
		payload = payload[MaxPayload:]
	}
	chunks = append(chunks, payload)
	return chunks
}
