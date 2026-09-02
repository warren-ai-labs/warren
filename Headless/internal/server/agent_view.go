package server

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/store"
)

const (
	agentAttachmentMaxBytes  = 64 * 1024 * 1024
	agentAttachmentChunkSize = 256 * 1024
	agentAttachmentTTL       = 15 * time.Minute
)

type agentUpload struct {
	sessionID    string
	attachmentID string
	name         string
	mime         string
	size         int64
	expectedHash string
	expiresAt    time.Time
	chunks       map[uint64][]byte
	state        string
	// path is a Host-local, mode-0600 file that a legacy PTY provider can read
	// after an attachment message is sent. The wire protocol still exposes only
	// the opaque attachment ID and never this path.
	path string
}

// AgentViewController is an optional provider-native bridge. Hosts that have
// a provider API can install one; ordinary text still has a legacy PTY path,
// but structured interaction and interrupt semantics require this bridge.
type AgentViewController interface {
	RespondInteraction(context.Context, api.AgentInteractionResponse) error
	InterruptTurn(context.Context, api.AgentTurnInterruptRequest) error
	SendMessage(context.Context, api.AgentMessageSendRequest) error
}

// AgentViewAtomicController is an optional stronger bridge for Hosts that can
// perform a provider-native interrupt and replacement in one transaction.
// AgentViewController remains deliberately small so existing embedders do not
// need to implement the new method; the built-in PTY bridge preserves ordering
// under a per-session action lock as a compatibility fallback.
type AgentViewAtomicController interface {
	InterruptAndSend(context.Context, api.AgentTurnInterruptRequest) error
}

// AgentViewCapabilities reports the capabilities this Service can actually
// execute. The protocol-level list describes the implementation's vocabulary,
// while this instance-level projection prevents a Host without a transcript
// finder or provider bridge from advertising controls it cannot honour.
func (s *Service) AgentViewCapabilities() []string {
	capabilities := []string{api.CapabilityRosterDelta}
	if s == nil {
		return capabilities
	}
	if nonNilInterface(s.AgentFinder) {
		capabilities = append(capabilities, api.CapabilityAgentTimeline)
	}
	if nonNilInterface(s.AgentController) {
		capabilities = append(capabilities,
			api.CapabilityAgentInteractions,
			api.CapabilityAgentInterrupt,
		)
	}
	// Attachments can use a provider-native controller when one is installed,
	// or the built-in PTY bridge below, which materializes each upload as a
	// Host-local file and includes its path in the provider prompt.
	if nonNilInterface(s.AgentController) || s.hasRuntimeAdapter() {
		capabilities = append(capabilities, api.CapabilityAgentAttachments)
	}
	return capabilities
}

func (s *Service) hasRuntimeAdapter() bool {
	if s == nil {
		return false
	}
	if nonNilInterface(s.Runtime) {
		return true
	}
	for _, runtime := range s.Runtimes {
		if nonNilInterface(runtime) {
			return true
		}
	}
	return false
}

func nonNilInterface(value any) bool {
	if value == nil {
		return false
	}
	rv := reflect.ValueOf(value)
	switch rv.Kind() {
	case reflect.Chan, reflect.Func, reflect.Interface, reflect.Map, reflect.Pointer, reflect.Slice:
		return !rv.IsNil()
	default:
		return true
	}
}

type agentActionCall struct {
	done        chan struct{}
	fingerprint string
	result      any
	err         error
}

// validateAttachmentName prevents a local path from becoming an attachment
// identity while retaining the user-visible basename.
func validateAttachmentName(value string) (string, error) {
	value = strings.TrimSpace(value)
	if value == "" {
		return "", errors.New("attachment name is required")
	}
	base := filepath.Base(value)
	if base == "." || base == ".." || base == string(filepath.Separator) || base != value ||
		strings.ContainsAny(value, "\\/\r\n\x00") || containsControl(value) {
		return "", errors.New("attachment name must be a file name")
	}
	return base, nil
}

func validateAttachmentPrepare(value api.AgentAttachmentPrepareRequest) (api.AgentAttachmentPrepareRequest, error) {
	name, err := validateAttachmentName(value.Name)
	if err != nil {
		return value, err
	}
	value.Name = name
	value.MIME = strings.TrimSpace(value.MIME)
	if value.MIME == "" || strings.ContainsAny(value.MIME, "\r\n\x00") || containsControl(value.MIME) {
		return value, errors.New("attachment MIME type is required")
	}
	if value.Size < 0 || value.Size > agentAttachmentMaxBytes {
		return value, fmt.Errorf("attachment size must be between 0 and %d bytes", agentAttachmentMaxBytes)
	}
	value.SHA256 = strings.ToLower(strings.TrimSpace(value.SHA256))
	if value.SHA256 != "" && (len(value.SHA256) != sha256.Size*2 || !isHex(value.SHA256)) {
		return value, errors.New("attachment sha256 is invalid")
	}
	return value, nil
}

func containsControl(value string) bool {
	for _, runeValue := range value {
		if runeValue < 0x20 || runeValue == 0x7f {
			return true
		}
	}
	return false
}

func isHex(value string) bool {
	_, err := hex.DecodeString(value)
	return err == nil
}

func (s *Service) ensureAgentViewState() {
	s.agentViewMu.Lock()
	if s.agentUploads == nil {
		s.agentUploads = make(map[string]*agentUpload)
	}
	if s.agentInteractionResults == nil {
		s.agentInteractionResults = make(map[string]api.AgentInteractionResult)
	}
	if s.agentMessageResults == nil {
		s.agentMessageResults = make(map[string]api.AgentMessageSendResult)
	}
	if s.agentInterruptResults == nil {
		s.agentInterruptResults = make(map[string]api.AgentTurnInterruptResult)
	}
	if s.agentActionFingerprints == nil {
		s.agentActionFingerprints = make(map[string]string)
	}
	if s.agentActionCalls == nil {
		s.agentActionCalls = make(map[string]*agentActionCall)
	}
	if s.agentSessionActionLocks == nil {
		s.agentSessionActionLocks = make(map[string]*sync.Mutex)
	}
	s.agentViewMu.Unlock()
}

func (s *Service) beginAgentAction(key, fingerprint string) (*agentActionCall, bool, error) {
	s.ensureAgentViewState()
	s.agentViewMu.Lock()
	defer s.agentViewMu.Unlock()
	if priorFingerprint, ok := s.agentActionFingerprints[key]; ok && priorFingerprint != fingerprint {
		return nil, false, errors.New("idempotency key was reused with different payload")
	}
	if call := s.agentActionCalls[key]; call != nil {
		if call.fingerprint != fingerprint {
			return nil, false, errors.New("idempotency key was reused with different payload")
		}
		return call, false, nil
	}
	call := &agentActionCall{done: make(chan struct{}), fingerprint: fingerprint}
	s.agentActionCalls[key] = call
	// Retain the fingerprint even when the provider later rejects the action.
	// A retry with the same payload may proceed, while a reused idempotency key
	// can never silently change its meaning after a failure.
	s.agentActionFingerprints[key] = fingerprint
	return call, true, nil
}

func agentActionFingerprint(value any) (string, error) {
	data, err := json.Marshal(value)
	if err != nil {
		return "", fmt.Errorf("encode idempotency payload: %w", err)
	}
	digest := sha256.Sum256(data)
	return hex.EncodeToString(digest[:]), nil
}

func (s *Service) cachedAgentActionFingerprint(key string) (string, bool) {
	s.ensureAgentViewState()
	s.agentViewMu.Lock()
	defer s.agentViewMu.Unlock()
	fingerprint, ok := s.agentActionFingerprints[key]
	return fingerprint, ok
}

func (s *Service) rememberAgentActionFingerprint(key, fingerprint string) {
	s.ensureAgentViewState()
	s.agentViewMu.Lock()
	s.agentActionFingerprints[key] = fingerprint
	s.agentViewMu.Unlock()
}

func (s *Service) finishAgentAction(key string, call *agentActionCall, result any, err error) {
	s.agentViewMu.Lock()
	call.result = result
	call.err = err
	if current := s.agentActionCalls[key]; current == call {
		delete(s.agentActionCalls, key)
	}
	close(call.done)
	s.agentViewMu.Unlock()
}

func waitAgentAction(ctx context.Context, call *agentActionCall) (any, error) {
	select {
	case <-call.done:
		return call.result, call.err
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

func (s *Service) lockAgentSessionAction(sessionID string) func() {
	s.ensureAgentViewState()
	s.agentViewMu.Lock()
	lock := s.agentSessionActionLocks[sessionID]
	if lock == nil {
		lock = &sync.Mutex{}
		s.agentSessionActionLocks[sessionID] = lock
	}
	s.agentViewMu.Unlock()
	lock.Lock()
	return lock.Unlock
}

func (s *Service) prepareAgentAttachment(
	ctx context.Context,
	sessionID string,
	request api.AgentAttachmentPrepareRequest,
) (api.AgentAttachmentPrepareResult, error) {
	if err := ctx.Err(); err != nil {
		return api.AgentAttachmentPrepareResult{}, err
	}
	sessionID = strings.TrimSpace(sessionID)
	if sessionID == "" {
		return api.AgentAttachmentPrepareResult{}, errors.New("session is required")
	}
	if _, ok := s.Session(sessionID); !ok {
		return api.AgentAttachmentPrepareResult{}, fmt.Errorf("session not found: %s", sessionID)
	}
	request.Session = sessionID
	request, err := validateAttachmentPrepare(request)
	if err != nil {
		return api.AgentAttachmentPrepareResult{}, err
	}
	s.ensureAgentViewState()
	attachmentID := store.NewID()
	uploadID := store.NewID()
	expiresAt := time.Now().UTC().Add(agentAttachmentTTL)
	s.agentViewMu.Lock()
	s.agentUploads[uploadID] = &agentUpload{
		sessionID: sessionID, attachmentID: attachmentID, name: request.Name,
		mime: request.MIME, size: request.Size, expectedHash: request.SHA256,
		expiresAt: expiresAt, chunks: make(map[uint64][]byte), state: "uploading",
	}
	s.agentViewMu.Unlock()
	return api.AgentAttachmentPrepareResult{
		AttachmentID: attachmentID,
		UploadID:     uploadID,
		ChunkSize:    agentAttachmentChunkSize,
		ExpiresAt:    expiresAt,
	}, nil
}

func (s *Service) putAgentAttachmentChunk(
	ctx context.Context,
	request api.AgentAttachmentChunkRequest,
) (api.AgentAttachmentResult, error) {
	if err := ctx.Err(); err != nil {
		return api.AgentAttachmentResult{}, err
	}
	request.Session = strings.TrimSpace(request.Session)
	request.UploadID = strings.TrimSpace(request.UploadID)
	if request.Session == "" || request.UploadID == "" {
		return api.AgentAttachmentResult{}, errors.New("session and uploadId are required")
	}
	data, err := base64.StdEncoding.DecodeString(strings.TrimSpace(request.Data))
	if err != nil {
		return api.AgentAttachmentResult{}, errors.New("attachment chunk data is not valid base64")
	}
	if err := api.AgentAttachmentChunkDigest(data, request.Length, request.SHA256); err != nil {
		return api.AgentAttachmentResult{}, err
	}
	s.ensureAgentViewState()
	s.agentViewMu.Lock()
	upload := s.agentUploads[request.UploadID]
	if upload == nil {
		s.agentViewMu.Unlock()
		return api.AgentAttachmentResult{}, errors.New("attachment upload not found")
	}
	if upload.sessionID != request.Session {
		s.agentViewMu.Unlock()
		return api.AgentAttachmentResult{}, errors.New("attachment session mismatch")
	}
	if upload.size == 0 && request.Sequence != 0 {
		s.agentViewMu.Unlock()
		return api.AgentAttachmentResult{}, errors.New("zero-length attachment only accepts sequence 0")
	}
	if upload.size > 0 && len(data) == 0 {
		s.agentViewMu.Unlock()
		return api.AgentAttachmentResult{}, errors.New("zero-length attachment chunk is not allowed")
	}
	if time.Now().After(upload.expiresAt) || upload.state == "aborted" {
		upload.state = "aborted"
		s.agentViewMu.Unlock()
		return api.AgentAttachmentResult{}, errors.New("attachment upload expired")
	}
	if upload.state != "uploading" {
		s.agentViewMu.Unlock()
		return api.AgentAttachmentResult{}, fmt.Errorf("attachment upload is %s", upload.state)
	}
	if existing, ok := upload.chunks[request.Sequence]; ok {
		if string(existing) != string(data) {
			s.agentViewMu.Unlock()
			return api.AgentAttachmentResult{}, errors.New("attachment chunk sequence already contains different data")
		}
		received := receivedUploadBytes(upload)
		s.agentViewMu.Unlock()
		return api.AgentAttachmentResult{Accepted: true, UploadID: request.UploadID, State: upload.state, Received: received}, nil
	}
	if request.Length > agentAttachmentChunkSize {
		s.agentViewMu.Unlock()
		return api.AgentAttachmentResult{}, fmt.Errorf("attachment chunk exceeds %d bytes", agentAttachmentChunkSize)
	}
	if receivedUploadBytes(upload)+int64(len(data)) > upload.size {
		s.agentViewMu.Unlock()
		return api.AgentAttachmentResult{}, errors.New("attachment upload exceeds declared size")
	}
	upload.chunks[request.Sequence] = append([]byte(nil), data...)
	received := receivedUploadBytes(upload)
	s.agentViewMu.Unlock()
	return api.AgentAttachmentResult{Accepted: true, UploadID: request.UploadID, State: "uploading", Received: received}, nil
}

func receivedUploadBytes(upload *agentUpload) int64 {
	var total int64
	for _, chunk := range upload.chunks {
		total += int64(len(chunk))
	}
	return total
}

func (s *Service) completeAgentAttachment(
	ctx context.Context,
	request api.AgentAttachmentCompleteRequest,
) (api.AgentAttachmentResult, error) {
	if err := ctx.Err(); err != nil {
		return api.AgentAttachmentResult{}, err
	}
	request.Session = strings.TrimSpace(request.Session)
	request.UploadID = strings.TrimSpace(request.UploadID)
	if request.Session == "" || request.UploadID == "" {
		return api.AgentAttachmentResult{}, errors.New("session and uploadId are required")
	}
	if request.Length < 0 {
		return api.AgentAttachmentResult{}, errors.New("attachment complete length is invalid")
	}
	request.SHA256 = strings.ToLower(strings.TrimSpace(request.SHA256))
	if request.SHA256 != "" && (len(request.SHA256) != sha256.Size*2 || !isHex(request.SHA256)) {
		return api.AgentAttachmentResult{}, errors.New("attachment complete sha256 is invalid")
	}
	s.ensureAgentViewState()
	s.agentViewMu.Lock()
	upload := s.agentUploads[request.UploadID]
	if upload == nil {
		s.agentViewMu.Unlock()
		return api.AgentAttachmentResult{}, errors.New("attachment upload not found")
	}
	if upload.sessionID != request.Session {
		s.agentViewMu.Unlock()
		return api.AgentAttachmentResult{}, errors.New("attachment session mismatch")
	}
	if time.Now().After(upload.expiresAt) {
		upload.state = "aborted"
		s.agentViewMu.Unlock()
		return api.AgentAttachmentResult{}, errors.New("attachment upload expired")
	}
	if upload.state != "uploading" && upload.state != "ready" {
		s.agentViewMu.Unlock()
		return api.AgentAttachmentResult{}, fmt.Errorf("attachment upload is %s", upload.state)
	}
	data, err := orderedUploadBytes(upload)
	if err != nil {
		s.agentViewMu.Unlock()
		return api.AgentAttachmentResult{}, err
	}
	if request.Length != int64(len(data)) {
		s.agentViewMu.Unlock()
		return api.AgentAttachmentResult{}, errors.New("attachment complete length mismatch")
	}
	if int64(len(data)) != upload.size {
		s.agentViewMu.Unlock()
		return api.AgentAttachmentResult{}, errors.New("attachment received length mismatch")
	}
	digest := sha256.Sum256(data)
	provided := strings.ToLower(strings.TrimSpace(request.SHA256))
	expected := upload.expectedHash
	if provided != "" && expected != "" && provided != expected {
		s.agentViewMu.Unlock()
		return api.AgentAttachmentResult{}, errors.New("attachment complete checksum mismatch")
	}
	if expected == "" {
		expected = provided
	}
	if expected != "" && hex.EncodeToString(digest[:]) != expected {
		s.agentViewMu.Unlock()
		return api.AgentAttachmentResult{}, errors.New("attachment complete checksum mismatch")
	}
	if upload.path == "" {
		path, pathErr := materializeAgentAttachment(upload.name, data)
		if pathErr != nil {
			s.agentViewMu.Unlock()
			return api.AgentAttachmentResult{}, fmt.Errorf("materialize attachment: %w", pathErr)
		}
		upload.path = path
	}
	upload.state = "ready"
	result := api.AgentAttachmentResult{Accepted: true, AttachmentID: upload.attachmentID, UploadID: request.UploadID, State: "ready", Received: int64(len(data))}
	s.agentViewMu.Unlock()
	return result, nil
}

// materializeAgentAttachment creates a private Host-local file for providers
// that only expose a terminal/PTY input surface. The original file name is
// retained so provider tools can infer the format, while the directory and
// file permissions prevent other users from reading the upload by default.
func materializeAgentAttachment(name string, data []byte) (string, error) {
	directory, err := os.MkdirTemp("", "warren-agent-attachments-")
	if err != nil {
		return "", err
	}
	path := filepath.Join(directory, name)
	if err := os.WriteFile(path, data, 0o600); err != nil {
		_ = os.RemoveAll(directory)
		return "", err
	}
	return path, nil
}

func orderedUploadBytes(upload *agentUpload) ([]byte, error) {
	if upload.size == 0 {
		return nil, nil
	}
	keys := make([]uint64, 0, len(upload.chunks))
	for key := range upload.chunks {
		keys = append(keys, key)
	}
	sort.Slice(keys, func(i, j int) bool { return keys[i] < keys[j] })
	result := make([]byte, 0, upload.size)
	for index, key := range keys {
		if key != uint64(index) {
			return nil, errors.New("attachment chunks are not contiguous")
		}
		result = append(result, upload.chunks[key]...)
	}
	return result, nil
}

func (s *Service) abortAgentAttachment(ctx context.Context, request api.AgentAttachmentAbortRequest) (api.AgentAttachmentResult, error) {
	if err := ctx.Err(); err != nil {
		return api.AgentAttachmentResult{}, err
	}
	request.Session = strings.TrimSpace(request.Session)
	request.UploadID = strings.TrimSpace(request.UploadID)
	if request.Session == "" || request.UploadID == "" {
		return api.AgentAttachmentResult{}, errors.New("session and uploadId are required")
	}
	s.ensureAgentViewState()
	s.agentViewMu.Lock()
	upload := s.agentUploads[request.UploadID]
	if upload == nil {
		s.agentViewMu.Unlock()
		return api.AgentAttachmentResult{}, errors.New("attachment upload not found")
	}
	if upload.sessionID != request.Session {
		s.agentViewMu.Unlock()
		return api.AgentAttachmentResult{}, errors.New("attachment session mismatch")
	}
	upload.state = "aborted"
	path := upload.path
	delete(s.agentUploads, request.UploadID)
	s.agentViewMu.Unlock()
	if path != "" {
		_ = os.RemoveAll(filepath.Dir(path))
	}
	return api.AgentAttachmentResult{Accepted: true, UploadID: request.UploadID, State: "aborted"}, nil
}

// reapAgentAttachments bounds the lifetime of Host-local upload files even
// when a client abandons an upload without sending the explicit abort RPC.
func (s *Service) reapAgentAttachments(now time.Time) {
	s.ensureAgentViewState()
	var paths []string
	s.agentViewMu.Lock()
	for uploadID, upload := range s.agentUploads {
		if now.Before(upload.expiresAt) {
			continue
		}
		if upload.path != "" {
			paths = append(paths, filepath.Dir(upload.path))
		}
		delete(s.agentUploads, uploadID)
	}
	s.agentViewMu.Unlock()
	for _, path := range paths {
		_ = os.RemoveAll(path)
	}
}

// cleanupAgentAttachments removes all materialized uploads during service
// shutdown. The upload map is intentionally device-local and need not survive
// a daemon restart.
func (s *Service) cleanupAgentAttachments() {
	s.ensureAgentViewState()
	var paths []string
	s.agentViewMu.Lock()
	for uploadID, upload := range s.agentUploads {
		if upload.path != "" {
			paths = append(paths, filepath.Dir(upload.path))
		}
		delete(s.agentUploads, uploadID)
	}
	s.agentViewMu.Unlock()
	for _, path := range paths {
		_ = os.RemoveAll(path)
	}
}

func (s *Service) attachmentReady(sessionID, attachmentID string) bool {
	s.ensureAgentViewState()
	s.agentViewMu.Lock()
	defer s.agentViewMu.Unlock()
	for _, upload := range s.agentUploads {
		if upload.sessionID == sessionID && upload.attachmentID == attachmentID && upload.state == "ready" && time.Now().Before(upload.expiresAt) {
			return true
		}
	}
	return false
}

func (s *Service) attachmentReferenceReady(sessionID string, reference api.AgentAttachmentRef) error {
	sessionID = strings.TrimSpace(sessionID)
	attachmentID := strings.TrimSpace(reference.AttachmentID)
	if attachmentID == "" {
		return errors.New("attachmentId is required")
	}
	var normalizedName string
	if reference.Name != "" {
		var err error
		normalizedName, err = validateAttachmentName(reference.Name)
		if err != nil {
			return err
		}
	}
	normalizedMIME := strings.TrimSpace(reference.MIME)
	if normalizedMIME != "" && containsControl(normalizedMIME) {
		return errors.New("attachment MIME type is invalid")
	}
	if reference.Size < 0 {
		return errors.New("attachment size is invalid")
	}
	s.agentViewMu.Lock()
	defer s.agentViewMu.Unlock()
	for _, upload := range s.agentUploads {
		if upload.sessionID != sessionID || upload.attachmentID != attachmentID {
			continue
		}
		if upload.state != "ready" || time.Now().After(upload.expiresAt) {
			return errors.New("attachment is not ready")
		}
		if normalizedName != "" && normalizedName != upload.name {
			return errors.New("attachment name does not match upload")
		}
		if normalizedMIME != "" && normalizedMIME != upload.mime {
			return errors.New("attachment MIME type does not match upload")
		}
		if reference.Size != 0 && reference.Size != upload.size {
			return errors.New("attachment size does not match upload")
		}
		return nil
	}
	return errors.New("attachment is not ready")
}

type materializedAgentAttachment struct {
	name string
	mime string
	size int64
	path string
}

// materializedAgentAttachmentFor resolves an opaque wire reference to the
// private file prepared at upload completion. It is the only place where the
// Host turns an attachment ID back into bytes; callers never trust a client
// supplied path.
func (s *Service) materializedAgentAttachmentFor(sessionID string, reference api.AgentAttachmentRef) (materializedAgentAttachment, error) {
	if err := s.attachmentReferenceReady(sessionID, reference); err != nil {
		return materializedAgentAttachment{}, err
	}
	s.ensureAgentViewState()
	s.agentViewMu.Lock()
	var upload *agentUpload
	for _, candidate := range s.agentUploads {
		if candidate.sessionID == sessionID && candidate.attachmentID == strings.TrimSpace(reference.AttachmentID) {
			upload = candidate
			break
		}
	}
	if upload == nil {
		s.agentViewMu.Unlock()
		return materializedAgentAttachment{}, errors.New("attachment is not ready")
	}
	if upload.path != "" {
		result := materializedAgentAttachment{name: upload.name, mime: upload.mime, size: upload.size, path: upload.path}
		s.agentViewMu.Unlock()
		return result, nil
	}
	// This fallback keeps uploads completed by an older in-process caller
	// usable after the bridge is enabled. New completions always set path.
	data, err := orderedUploadBytes(upload)
	if err != nil {
		s.agentViewMu.Unlock()
		return materializedAgentAttachment{}, err
	}
	name, mime, size := upload.name, upload.mime, upload.size
	s.agentViewMu.Unlock()
	path, err := materializeAgentAttachment(name, data)
	if err != nil {
		return materializedAgentAttachment{}, fmt.Errorf("materialize attachment: %w", err)
	}
	s.agentViewMu.Lock()
	published := false
	for _, candidate := range s.agentUploads {
		if candidate == upload {
			published = true
			if candidate.path == "" {
				candidate.path = path
			} else {
				path = candidate.path
			}
			break
		}
	}
	s.agentViewMu.Unlock()
	if !published {
		_ = os.RemoveAll(filepath.Dir(path))
		return materializedAgentAttachment{}, errors.New("attachment is no longer available")
	}
	return materializedAgentAttachment{name: name, mime: mime, size: size, path: path}, nil
}

func (s *Service) agentMessageTextWithAttachments(request api.AgentMessageSendRequest) (string, error) {
	if len(request.Attachments) == 0 {
		return request.Text, nil
	}
	var builder strings.Builder
	builder.WriteString(request.Text)
	builder.WriteString("\n\nAttached files are available on the Host:\n")
	for _, reference := range request.Attachments {
		attachment, err := s.materializedAgentAttachmentFor(request.Session, reference)
		if err != nil {
			return "", fmt.Errorf("attachment %s: %w", reference.AttachmentID, err)
		}
		builder.WriteString("- ")
		builder.WriteString(attachment.name)
		if attachment.mime != "" {
			builder.WriteString(" (")
			builder.WriteString(attachment.mime)
			builder.WriteString(")")
		}
		if attachment.size >= 0 {
			builder.WriteString(fmt.Sprintf(" [%d bytes]", attachment.size))
		}
		builder.WriteString(": ")
		builder.WriteString(attachment.path)
		builder.WriteByte('\n')
	}
	return builder.String(), nil
}

func (s *Service) sendAgentMessage(ctx context.Context, request api.AgentMessageSendRequest) (api.AgentMessageSendResult, error) {
	if err := ctx.Err(); err != nil {
		return api.AgentMessageSendResult{}, err
	}
	request.Session = strings.TrimSpace(request.Session)
	request.ClientMessageID = strings.TrimSpace(request.ClientMessageID)
	request.Text = strings.TrimSpace(request.Text)
	if request.Session == "" || request.ClientMessageID == "" ||
		(request.Text == "" && len(request.Attachments) == 0) {
		return api.AgentMessageSendResult{}, errors.New("session, clientMessageId and text or attachments are required")
	}
	if request.Text == "" {
		request.Text = "Please inspect the attached file(s)."
	}
	if _, ok := s.Session(request.Session); !ok {
		return api.AgentMessageSendResult{}, fmt.Errorf("session not found: %s", request.Session)
	}
	fingerprint, err := agentActionFingerprint(request)
	if err != nil {
		return api.AgentMessageSendResult{}, err
	}
	s.ensureAgentViewState()
	cacheKey := request.Session + ":" + request.ClientMessageID
	actionKey := "message:" + cacheKey
	s.agentViewMu.Lock()
	if prior, ok := s.agentMessageResults[cacheKey]; ok {
		priorFingerprint := s.agentActionFingerprints[actionKey]
		s.agentViewMu.Unlock()
		if priorFingerprint != fingerprint {
			return api.AgentMessageSendResult{}, errors.New("idempotency key was reused with different payload")
		}
		return prior, nil
	}
	s.agentViewMu.Unlock()
	call, leader, beginErr := s.beginAgentAction(actionKey, fingerprint)
	if beginErr != nil {
		return api.AgentMessageSendResult{}, beginErr
	}
	if !leader {
		value, err := waitAgentAction(ctx, call)
		if err != nil {
			return api.AgentMessageSendResult{}, err
		}
		result, ok := value.(api.AgentMessageSendResult)
		if !ok {
			return api.AgentMessageSendResult{}, errors.New("invalid cached agent message result")
		}
		return result, nil
	}
	for _, attachment := range request.Attachments {
		if err := s.attachmentReferenceReady(request.Session, attachment); err != nil {
			s.finishAgentAction(actionKey, call, nil, err)
			return api.AgentMessageSendResult{}, fmt.Errorf("attachment %s: %w", attachment.AttachmentID, err)
		}
	}
	if controller := s.AgentController; nonNilInterface(controller) {
		if err := controller.SendMessage(ctx, request); err != nil {
			s.finishAgentAction(actionKey, call, nil, err)
			return api.AgentMessageSendResult{}, err
		}
	} else {
		// Keep legacy CLIs usable while preserving one structured request and one
		// idempotency key at the Host boundary.
		session, _ := s.Session(request.Session)
		runtime := s.runtimeFor(session)
		if runtime == nil {
			err := errors.New("agent message transport is unavailable")
			s.finishAgentAction(actionKey, call, nil, err)
			return api.AgentMessageSendResult{}, errors.New("agent message transport is unavailable")
		}
		unlock := s.lockAgentSessionAction(request.Session)
		text := request.Text
		if len(request.Attachments) > 0 {
			text, err = s.agentMessageTextWithAttachments(request)
			if err != nil {
				unlock()
				s.finishAgentAction(actionKey, call, nil, err)
				return api.AgentMessageSendResult{}, err
			}
		}
		err = sendAgentMessageInput(ctx, runtime, session.Runtime, text)
		unlock()
		if err != nil {
			s.finishAgentAction(actionKey, call, nil, err)
			return api.AgentMessageSendResult{}, err
		}
	}
	result := api.AgentMessageSendResult{Accepted: true, Session: request.Session, ClientMessageID: request.ClientMessageID}
	s.agentViewMu.Lock()
	s.agentMessageResults[cacheKey] = result
	s.agentActionFingerprints[actionKey] = fingerprint
	s.agentViewMu.Unlock()
	s.finishAgentAction(actionKey, call, result, nil)
	return result, nil
}

func (s *Service) existingAgentMessageIdentity(sessionID, clientMessageID, fingerprint string) error {
	cacheKey := sessionID + ":" + clientMessageID
	actionKey := "message:" + cacheKey
	s.agentViewMu.Lock()
	defer s.agentViewMu.Unlock()
	if prior, ok := s.agentActionFingerprints[actionKey]; ok && prior != fingerprint {
		return errors.New("idempotency key was reused with different payload")
	}
	if _, ok := s.agentMessageResults[cacheKey]; ok {
		return errors.New("clientMessageId has already been accepted")
	}
	if _, ok := s.agentActionCalls[actionKey]; ok {
		return errors.New("clientMessageId is already in progress")
	}
	return nil
}

func sendAgentMessageInput(ctx context.Context, runtime Runtime, sessionID, text string) error {
	if err := runtime.Input(ctx, sessionID, []byte(strings.ReplaceAll(text, "\n", "\r"))); err != nil {
		return err
	}
	return runtime.Input(ctx, sessionID, []byte{0x1b, 0x5b, 0x31, 0x33, 0x75})
}

// interruptAgentTurnInput sends the terminal interrupt byte (Ctrl+C) and, for
// send_now, types the replacement message after the turn is cancelled. It is
// the PTY fallback for Hosts without a provider-native AgentController.
func interruptAgentTurnInput(ctx context.Context, runtime Runtime, sessionID string, request api.AgentTurnInterruptRequest) error {
	if request.Replacement == nil {
		return interruptAgentTurnInputText(ctx, runtime, sessionID, "")
	}
	return interruptAgentTurnInputText(ctx, runtime, sessionID, request.Replacement.Text)
}

func interruptAgentTurnInputText(ctx context.Context, runtime Runtime, sessionID, replacementText string) error {
	if err := runtime.Input(ctx, sessionID, []byte{0x03}); err != nil {
		return err
	}
	if replacementText != "" {
		return sendAgentMessageInput(ctx, runtime, sessionID, replacementText)
	}
	return nil
}

func (s *Service) respondAgentInteraction(ctx context.Context, request api.AgentInteractionResponse) (api.AgentInteractionResult, error) {
	if err := ctx.Err(); err != nil {
		return api.AgentInteractionResult{}, err
	}
	request.Session = strings.TrimSpace(request.Session)
	request.RequestID = strings.TrimSpace(request.RequestID)
	request.Kind = strings.ToLower(strings.TrimSpace(request.Kind))
	if request.Session == "" || request.RequestID == "" || (request.Kind != "question" && request.Kind != "permission") {
		return api.AgentInteractionResult{}, errors.New("session, requestId and a valid interaction kind are required")
	}
	if _, ok := s.Session(request.Session); !ok {
		return api.AgentInteractionResult{}, fmt.Errorf("session not found: %s", request.Session)
	}
	fingerprint, err := agentActionFingerprint(request)
	if err != nil {
		return api.AgentInteractionResult{}, err
	}
	// The request ID is the provider's stable identity. Treat a repeated
	// response as an idempotent replay and never invoke a provider bridge twice.
	s.ensureAgentViewState()
	cacheKey := request.Session + ":" + request.RequestID
	actionKey := "interaction:" + cacheKey
	s.agentViewMu.Lock()
	if prior, ok := s.agentInteractionResults[cacheKey]; ok {
		priorFingerprint := s.agentActionFingerprints[actionKey]
		s.agentViewMu.Unlock()
		if priorFingerprint != fingerprint {
			return api.AgentInteractionResult{}, errors.New("idempotency key was reused with different payload")
		}
		return prior, nil
	}
	s.agentViewMu.Unlock()
	call, leader, beginErr := s.beginAgentAction(actionKey, fingerprint)
	if beginErr != nil {
		return api.AgentInteractionResult{}, beginErr
	}
	if !leader {
		value, err := waitAgentAction(ctx, call)
		if err != nil {
			return api.AgentInteractionResult{}, err
		}
		result, ok := value.(api.AgentInteractionResult)
		if !ok {
			return api.AgentInteractionResult{}, errors.New("invalid cached agent interaction result")
		}
		return result, nil
	}
	// If the Host has already projected a terminal state for this request, the
	// interaction is stale. Keep the event in history so clients can refresh
	// instead of pretending an old card was resolved.
	if state, found := s.agentInteractionState(request.Session, request.RequestID, request.Kind); found && state != "pending" && state != "submitting" {
		err := fmt.Errorf("interaction request is %s", state)
		s.finishAgentAction(actionKey, call, nil, err)
		return api.AgentInteractionResult{}, err
	}
	if controller := s.AgentController; nonNilInterface(controller) {
		if err := controller.RespondInteraction(ctx, request); err != nil {
			s.finishAgentAction(actionKey, call, nil, err)
			return api.AgentInteractionResult{}, err
		}
	} else {
		err := errors.New("agent interaction transport is unavailable")
		s.finishAgentAction(actionKey, call, nil, err)
		return api.AgentInteractionResult{}, err
	}
	result := api.AgentInteractionResult{Accepted: true, Session: request.Session, RequestID: request.RequestID, Kind: request.Kind}
	s.agentViewMu.Lock()
	s.agentInteractionResults[cacheKey] = result
	s.agentActionFingerprints[actionKey] = fingerprint
	s.agentViewMu.Unlock()
	s.finishAgentAction(actionKey, call, result, nil)
	return result, nil
}

func (s *Service) interruptAgentTurn(ctx context.Context, request api.AgentTurnInterruptRequest) (api.AgentTurnInterruptResult, error) {
	if err := ctx.Err(); err != nil {
		return api.AgentTurnInterruptResult{}, err
	}
	request.Session = strings.TrimSpace(request.Session)
	request.Reason = strings.ToLower(strings.TrimSpace(request.Reason))
	if request.Session == "" || request.Turn == 0 || (request.Reason != "cancel" && request.Reason != "send_now") {
		return api.AgentTurnInterruptResult{}, errors.New("session, turn and reason (cancel or send_now) are required")
	}
	if request.Reason == "send_now" {
		if request.Replacement == nil {
			return api.AgentTurnInterruptResult{}, errors.New("send_now requires a replacement message")
		}
		if request.Replacement.Session == "" {
			request.Replacement.Session = request.Session
		}
		if request.Replacement.Session != request.Session {
			return api.AgentTurnInterruptResult{}, errors.New("replacement session mismatch")
		}
		request.Replacement.ClientMessageID = strings.TrimSpace(request.Replacement.ClientMessageID)
		request.Replacement.Text = strings.TrimSpace(request.Replacement.Text)
		if request.Replacement.Text == "" && len(request.Replacement.Attachments) > 0 {
			request.Replacement.Text = "Please inspect the attached file(s)."
		}
	}
	if _, ok := s.Session(request.Session); !ok {
		return api.AgentTurnInterruptResult{}, fmt.Errorf("session not found: %s", request.Session)
	}
	if request.Replacement != nil && request.Replacement.ClientMessageID == "" {
		return api.AgentTurnInterruptResult{}, errors.New("replacement clientMessageId is required")
	}
	if request.Replacement != nil {
		if request.Replacement.Text == "" {
			return api.AgentTurnInterruptResult{}, errors.New("replacement text is required")
		}
	}
	var replacementFingerprint string
	var err error
	if request.Replacement != nil {
		replacementFingerprint, err = agentActionFingerprint(*request.Replacement)
		if err != nil {
			return api.AgentTurnInterruptResult{}, err
		}
	}
	fingerprint, err := agentActionFingerprint(request)
	if err != nil {
		return api.AgentTurnInterruptResult{}, err
	}
	s.ensureAgentViewState()
	cacheKey := fmt.Sprintf("%s:%d:%s:%s", request.Session, request.Turn, request.Reason, replacementID(request.Replacement))
	actionKey := "interrupt:" + cacheKey
	s.agentViewMu.Lock()
	if prior, ok := s.agentInterruptResults[cacheKey]; ok {
		priorFingerprint := s.agentActionFingerprints[actionKey]
		s.agentViewMu.Unlock()
		if priorFingerprint != fingerprint {
			return api.AgentTurnInterruptResult{}, errors.New("idempotency key was reused with different payload")
		}
		return prior, nil
	}
	s.agentViewMu.Unlock()
	call, leader, beginErr := s.beginAgentAction(actionKey, fingerprint)
	if beginErr != nil {
		return api.AgentTurnInterruptResult{}, beginErr
	}
	if !leader {
		value, err := waitAgentAction(ctx, call)
		if err != nil {
			return api.AgentTurnInterruptResult{}, err
		}
		result, ok := value.(api.AgentTurnInterruptResult)
		if !ok {
			return api.AgentTurnInterruptResult{}, errors.New("invalid cached agent interrupt result")
		}
		return result, nil
	}
	if request.Replacement != nil {
		if err := s.existingAgentMessageIdentity(request.Session, request.Replacement.ClientMessageID, replacementFingerprint); err != nil {
			s.finishAgentAction(actionKey, call, nil, err)
			return api.AgentTurnInterruptResult{}, err
		}
	}
	if err := s.validateCurrentAgentTurn(request.Session, request.Turn); err != nil {
		s.finishAgentAction(actionKey, call, nil, err)
		return api.AgentTurnInterruptResult{}, err
	}
	if request.Replacement != nil {
		for _, attachment := range request.Replacement.Attachments {
			if err := s.attachmentReferenceReady(request.Session, attachment); err != nil {
				s.finishAgentAction(actionKey, call, nil, err)
				return api.AgentTurnInterruptResult{}, fmt.Errorf("attachment %s: %w", attachment.AttachmentID, err)
			}
		}
	}
	if controller := s.AgentController; nonNilInterface(controller) {
		var err error
		if request.Replacement != nil {
			atomicController, atomicOK := controller.(AgentViewAtomicController)
			if !atomicOK || !nonNilInterface(atomicController) {
				err = errors.New("agent send_now transport is unavailable")
			} else {
				err = atomicController.InterruptAndSend(ctx, request)
			}
		} else {
			err = controller.InterruptTurn(ctx, request)
		}
		if err != nil {
			s.finishAgentAction(actionKey, call, nil, err)
			return api.AgentTurnInterruptResult{}, err
		}
	} else {
		// PTY fallback: cancel the in-flight turn with the terminal interrupt
		// byte and type a send_now replacement, under the same per-session
		// action lock as the message path.
		session, _ := s.Session(request.Session)
		runtime := s.runtimeFor(session)
		if runtime == nil {
			err := errors.New("agent interrupt transport is unavailable")
			s.finishAgentAction(actionKey, call, nil, err)
			return api.AgentTurnInterruptResult{}, err
		}
		unlock := s.lockAgentSessionAction(request.Session)
		var err error
		if request.Replacement != nil && len(request.Replacement.Attachments) > 0 {
			text, textErr := s.agentMessageTextWithAttachments(*request.Replacement)
			if textErr != nil {
				unlock()
				s.finishAgentAction(actionKey, call, nil, textErr)
				return api.AgentTurnInterruptResult{}, textErr
			}
			err = interruptAgentTurnInputText(ctx, runtime, session.Runtime, text)
		} else {
			err = interruptAgentTurnInput(ctx, runtime, session.Runtime, request)
		}
		unlock()
		if err != nil {
			s.finishAgentAction(actionKey, call, nil, err)
			return api.AgentTurnInterruptResult{}, err
		}
	}
	result := api.AgentTurnInterruptResult{Accepted: true, Session: request.Session, Turn: request.Turn, Status: "accepted"}
	if request.Replacement != nil {
		result.ClientMessageID = request.Replacement.ClientMessageID
	}
	s.agentViewMu.Lock()
	s.agentInterruptResults[cacheKey] = result
	s.agentActionFingerprints[actionKey] = fingerprint
	if request.Replacement != nil {
		messageKey := request.Session + ":" + request.Replacement.ClientMessageID
		s.agentMessageResults[messageKey] = api.AgentMessageSendResult{
			Accepted: true, Session: request.Session,
			ClientMessageID: request.Replacement.ClientMessageID,
		}
		s.agentActionFingerprints["message:"+messageKey] = replacementFingerprint
	}
	s.agentViewMu.Unlock()
	s.finishAgentAction(actionKey, call, result, nil)
	return result, nil
}

func (s *Service) validateCurrentAgentTurn(sessionID string, requested uint64) error {
	s.lazyInit()
	s.agentsMu.Lock()
	entry := s.agents[sessionID]
	s.agentsMu.Unlock()
	if entry == nil {
		return fmt.Errorf("turn %d is not active", requested)
	}
	entry.mu.Lock()
	current := entry.turn
	entry.mu.Unlock()
	if current.ID != requested || current.Status != api.AgentTurnStarted {
		return fmt.Errorf("turn %d is not active", requested)
	}
	return nil
}

func replacementID(value *api.AgentMessageSendRequest) string {
	if value == nil {
		return ""
	}
	return strings.TrimSpace(value.ClientMessageID)
}

// agentInteractionState returns the latest state for a structured interaction
// when the provider supplied one. A missing event is intentionally treated as
// unknown: legacy bridges may accept a response before the first transcript
// poll, while an explicitly terminal event is safe to reject as stale.
func (s *Service) agentInteractionState(sessionID, requestID, kind string) (string, bool) {
	history := s.agentHistory(sessionID)
	for index := len(history) - 1; index >= 0; index-- {
		event := history[index]
		eventKind := strings.ToLower(strings.ReplaceAll(strings.TrimSpace(event.Type), "-", "_"))
		if eventKind != kind {
			continue
		}
		if event.Payload == nil {
			continue
		}
		value, ok := event.Payload["requestId"].(string)
		if !ok {
			value, ok = event.Payload["request_id"].(string)
		}
		if !ok || strings.TrimSpace(value) != requestID {
			continue
		}
		state, _ := event.Payload["state"].(string)
		state = strings.ToLower(strings.TrimSpace(state))
		if state == "" {
			state = "pending"
		}
		return state, true
	}
	return "", false
}
