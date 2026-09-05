package controlplane

import (
	"crypto/rand"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
)

const (
	// relayVersion is the only wire version emitted by the owned Relay. The
	// old v1 framing deliberately is not accepted by a v2 connection.
	relayVersion byte = 2
	headerSize        = 22

	frameOpen         byte = 1
	frameClose        byte = 2
	frameText         byte = 3
	frameBinary       byte = 4
	frameHTTPHeaders  byte = 5
	frameData         byte = 6
	frameEnd          byte = 7
	frameWindowUpdate byte = 8
	frameError        byte = 9
)

const (
	maxRelayMessageBytes = 8 * 1024 * 1024
	initialStreamWindow  = 16 * 1024 * 1024
	maxHostStreams       = 128
	maxPublicStreams     = 64
)

var relayMagic = [4]byte{'B', 'R', 'L', 'Y'}

type relayFrame struct {
	Kind         byte
	ConnectionID connectionID
	Payload      []byte
}

// streamOpen describes the owner of a BRLY/2 stream. Keep this metadata
// intentionally small: route authorization is performed by Relay before an
// OPEN is emitted and the Host treats all values as untrusted input.
type streamOpen struct {
	Class      string `json:"class"`
	Version    string `json:"version,omitempty"`
	RequestID  string `json:"request_id,omitempty"`
	DeadlineMS int64  `json:"deadline_ms,omitempty"`
	RouteID    string `json:"route_id,omitempty"`
	HostID     string `json:"host_id,omitempty"`
	ClientID   string `json:"client_id,omitempty"`
	Token      string `json:"access_token,omitempty"`
	// PublicRoute is emitted only for an explicitly public route. The Host
	// uses it to authenticate the public WebSocket without exposing a daemon
	// token through Relay headers or URL fragments.
	PublicRoute bool `json:"public_route,omitempty"`
}

func (open streamOpen) encode() ([]byte, error) {
	if open.Class == "" {
		return nil, errors.New("stream class is required")
	}
	return json.Marshal(open)
}

func decodeStreamOpen(payload []byte) (streamOpen, error) {
	if len(payload) == 0 || len(payload) > 64*1024 {
		return streamOpen{}, errors.New("invalid stream open metadata")
	}
	var open streamOpen
	if err := json.Unmarshal(payload, &open); err != nil || open.Class == "" {
		return streamOpen{}, errors.New("invalid stream open metadata")
	}
	return open, nil
}

type connectionID [16]byte

func newConnectionID() (connectionID, error) {
	var id connectionID
	_, err := rand.Read(id[:])
	return id, err
}

func encodeRelayFrame(frame relayFrame) []byte {
	if len(frame.Payload) > maxRelayMessageBytes {
		return nil
	}
	encoded := make([]byte, headerSize+len(frame.Payload))
	copy(encoded[:4], relayMagic[:])
	encoded[4] = relayVersion
	encoded[5] = frame.Kind
	copy(encoded[6:22], frame.ConnectionID[:])
	copy(encoded[22:], frame.Payload)
	return encoded
}

func decodeRelayFrame(data []byte) (relayFrame, error) {
	if len(data) < headerSize || string(data[:4]) != string(relayMagic[:]) {
		return relayFrame{}, errors.New("invalid relay frame header")
	}
	if data[4] != relayVersion {
		return relayFrame{}, errors.New("unsupported relay frame version")
	}
	if data[5] < frameOpen || data[5] > frameError {
		return relayFrame{}, errors.New("invalid relay frame kind")
	}
	if len(data)-headerSize > maxRelayMessageBytes {
		return relayFrame{}, errors.New("relay frame exceeds limit")
	}
	var id connectionID
	copy(id[:], data[6:22])
	return relayFrame{
		Kind:         data[5],
		ConnectionID: id,
		Payload:      append([]byte(nil), data[22:]...),
	}, nil
}

// encodeWindowCredit and decodeWindowCredit use a fixed-width unsigned value
// so malformed JSON or integer overflows cannot grant unbounded credit.
func encodeWindowCredit(credit uint64) []byte {
	data := make([]byte, 8)
	binary.BigEndian.PutUint64(data, credit)
	return data
}

func decodeWindowCredit(data []byte) (uint64, error) {
	if len(data) != 8 {
		return 0, fmt.Errorf("invalid window update payload")
	}
	return binary.BigEndian.Uint64(data), nil
}
