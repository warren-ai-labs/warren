package server

import (
	"context"
	"errors"
	"fmt"
	"io"
	"sync"
	"time"

	"github.com/abcdlsj/ghostline"
	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/output"
)

const branchAtomicReanchor = "atomic_reanchor"

// logRecoveryOutcome records which replay path served a peer and how many
// bytes it carried. This is pure observability for the warm-surface
// investigation: composer corruption reports need branch, byte volume, and
// the runtime width at capture time to be diagnosable after the fact.
func (s *Service) logRecoveryOutcome(
	sessionID string,
	method string,
	branch string,
	anchor *output.Anchor,
	bytes int,
	frames int,
	upper uint64,
) {
	s.outputMu.Lock()
	size, known := s.runtimeSizes[sessionID]
	s.outputMu.Unlock()
	sizeLabel := "unknown"
	if known {
		sizeLabel = fmt.Sprintf("%dx%d", size.Columns, size.Rows)
	}
	anchorLabel := "none"
	if anchor != nil {
		anchorLabel = fmt.Sprintf("epoch=%d sequence=%d", anchor.Epoch, anchor.Sequence)
	}
	s.logInfo("recovery outcome",
		"session", sessionID,
		"method", method,
		"branch", string(branch),
		"anchor", anchorLabel,
		"bytes", bytes,
		"frames", frames,
		"upper", upper,
		"runtimeSize", sizeLabel,
	)
}

func (s *Service) recordOutput(sessionID string, data []byte) {
	s.recordOutputWithCursor(sessionID, data, nil)
}

// recordCursorOutput records one complete v1 reader batch. Cursor is opaque:
// it becomes durable only after the complete batch has entered the browser
// ring, preserving the at-least-once recovery boundary across a Host crash.
func (s *Service) recordCursorOutput(sessionID string, data []byte, cursor ghostline.Cursor) {
	s.recordOutputWithCursor(sessionID, data, &cursor)
}

func (s *Service) recordOutputWithCursor(sessionID string, data []byte, cursor *ghostline.Cursor) {
	s.recordOutputWithCursorMode(sessionID, data, cursor, true)
}

// recordOutputWithCursorMode appends one complete reader batch before making
// it visible to peers. A recovery boundary can use broadcast=false while it
// catches the Warren ring up to the Ghostline checkpoint cursor: those bytes
// are already represented by the atomic state and must not be sent as a
// second live stream to existing peers.
func (s *Service) recordOutputWithCursorMode(
	sessionID string,
	data []byte,
	cursor *ghostline.Cursor,
	broadcast bool,
) {
	s.outputMu.Lock()
	outputSession := s.outputs[sessionID]
	attached := len(s.peers[sessionID]) > 0
	s.outputMu.Unlock()
	if outputSession == nil || len(data) == 0 {
		return
	}
	frames := make([]output.Frame, 0, len(data)/output.MaxPayload+1)
	var replies [][]byte
	for _, chunk := range output.SplitPayload(data) {
		outputSession.mu.Lock()
		frame, err := outputSession.ring.Append(sessionID, chunk)
		if !attached {
			replies = append(replies, outputSession.responder.Feed(chunk)...)
		}
		outputSession.mu.Unlock()
		if err != nil {
			continue
		}
		frames = append(frames, frame)
	}
	if len(frames) == 0 {
		return
	}

	outputSession.mu.Lock()
	if cursor != nil {
		outputSession.outputCursor = *cursor
		outputSession.hasOutputCursor = true
	}
	epoch := outputSession.ring.Epoch
	sequence := outputSession.ring.Upper()
	persist := sequence-outputSession.persistedSequence >= cursorPersistEvery
	if persist {
		outputSession.persistedSequence = sequence
	}
	outputSession.mu.Unlock()

	// Ring first, then clients: recovery is always authoritative even when a
	// peer cannot keep up and has to reconnect. A v1 cursor is not persisted
	// until all frames from this reader batch were appended above. Recovery-gap
	// bytes deliberately skip the broadcast because the atomic state already
	// covers them; every peer has its own direct reader at that boundary.
	if broadcast {
		for _, frame := range frames {
			s.broadcastFrame(frame)
		}
	}
	if persist {
		s.persistOutputCursor(outputSession, epoch, sequence)
	}
	for _, reply := range replies {
		_ = s.runtimeForKind(outputSession.runtimeKind).Input(context.Background(), outputSession.runtimeName, reply)
	}
}

func (s *Service) persistOutputCursor(outputSession *outputSession, _, _ uint64) {
	if s.Store == nil {
		return
	}
	outputSession.mu.Lock()
	err := s.persistCursorLocked(outputSession)
	outputSession.mu.Unlock()
	if err != nil {
		s.logWarn("persist output cursor", "session", outputSession.sessionID, "error", err)
	}
}

func (s *Service) persistCursorLocked(outputSession *outputSession) error {
	epoch := outputSession.ring.Epoch
	sequence := outputSession.ring.Upper()
	return s.Store.Update(func(value *api.State) error {
		for index := range value.Sessions {
			if value.Sessions[index].ID == outputSession.sessionID && value.Sessions[index].Lifecycle == "running" {
				value.Sessions[index].Epoch = epoch
				value.Sessions[index].Sequence = sequence
				if outputSession.hasOutputCursor {
					value.Sessions[index].OutputCursor = outputSession.outputCursor.String()
				}
			}
		}
		return nil
	})
}

func (s *Service) broadcastFrame(frame output.Frame) {
	// Resolve the recipients before touching the session broadcast lock. Every
	// subscriber that negotiated a direct Ghostline reader is served from its
	// own paired stream and is excluded below, so this set is empty for a
	// session whose only subscribers are current desktop clients. Locking for
	// an empty set is what turned ordinary contention into a peer reset: the
	// timeout path closed every subscription on the session even though this
	// frame was never going to be written to any of them.
	if len(s.sharedBroadcastPeers(frame.SessionID)) == 0 {
		return
	}
	encoded, err := output.EncodeOutput(frame.SessionID, frame.Epoch, frame.Sequence, frame.Payload)
	if err != nil {
		return
	}
	lock := s.broadcastLock(frame.SessionID)
	if !lock.TryLock() {
		// The same lock is held by attach recovery while it captures a
		// checkpoint and by focus/resize while the runtime applies a PTY size.
		// Waiting preserves frame ordering (the ring already owns these bytes)
		// and is always preferable to a reset, so the deadline has to cover the
		// slowest legitimate holder rather than a shorter guess.
		ctx, cancel := context.WithTimeout(context.Background(), s.broadcastLockWait())
		err := lock.LockContext(ctx)
		cancel()
		if err != nil {
			// Only the peers that were about to receive this frame can have a
			// gap. Peers reading their own direct stream are unaffected and must
			// keep their connection: one contended session must never drop the
			// other sessions multiplexed onto the same WebSocket.
			s.forcePeerReanchor(frame.SessionID, s.sharedBroadcastPeers(frame.SessionID))
			return
		}
	}
	defer lock.Unlock()
	// Re-resolve under the lock. An attach we waited on promotes its peer to a
	// direct reader, and that peer must not also receive this frame.
	for _, peer := range s.sharedBroadcastPeers(frame.SessionID) {
		if !peer.enqueueBinary(encoded) {
			s.detachPeer(peer, frame.SessionID)
		}
	}
}

// sharedBroadcastPeers lists the subscribers of a session that are still served
// from the shared ring. A peer holding a direct Ghostline reader — reserved
// during recovery or already running — receives that stream instead and is
// excluded.
func (s *Service) sharedBroadcastPeers(sessionID string) []*wsPeer {
	s.outputMu.Lock()
	defer s.outputMu.Unlock()
	peers := make([]*wsPeer, 0, len(s.peers[sessionID]))
	for peer := range s.peers[sessionID] {
		if streams := s.peerOutputs[peer]; streams != nil {
			if _, direct := streams[sessionID]; direct {
				continue
			}
		}
		peers = append(peers, peer)
	}
	return peers
}

// broadcastLockWait bounds how long a shared-ring frame waits for the session
// broadcast lock. Every legitimate holder is itself bounded by the command
// timeout, so reaching this deadline means the lock leaked rather than that the
// receiving peer is slow.
func (s *Service) broadcastLockWait() time.Duration {
	return s.commandTimeout()
}

func (s *Service) broadcastLock(sessionID string) *sessionLock {
	s.outputMu.Lock()
	defer s.outputMu.Unlock()
	s.lazyInitLocked()
	lock := s.broadcastLocks[sessionID]
	if lock == nil {
		lock = newSessionLock()
		s.broadcastLocks[sessionID] = lock
	}
	return lock
}

// agentLock serializes one session's canonical Agent snapshot reads with the
// live increments that follow them, so a subscriber never sees a gap or a
// duplicate between its history page and the stream. Terminal output never
// takes this lock, and Agent paths never take the broadcast lock.
func (s *Service) agentLock(sessionID string) *sessionLock {
	s.outputMu.Lock()
	defer s.outputMu.Unlock()
	s.lazyInitLocked()
	lock := s.agentLocks[sessionID]
	if lock == nil {
		lock = newSessionLock()
		s.agentLocks[sessionID] = lock
	}
	return lock
}

// forcePeerReanchor resets the given subscribers after a shared-ring frame
// could not be delivered, so a gap is never papered over silently. Closing the
// connection is the only in-protocol resync signal: a reconnecting peer always
// receives a fresh atomic state, so no recovery mode is carried in the ring.
// The caller decides which peers are affected — this must not extend to peers
// that were never a recipient of the undelivered frame.
func (s *Service) forcePeerReanchor(sessionID string, peers []*wsPeer) {
	if len(peers) == 0 {
		return
	}
	s.logWarn("force peer reanchor", "session", sessionID, "peers", len(peers))
	for _, peer := range peers {
		peer.closeWithReason("force_reanchor")
	}
}

// prepareAttach serializes recovery and holds the shared broadcast boundary.
// The shared reader is stopped and joined before the runtime checkpoint.  This
// is a short pause, but it is the only way to prove that no reader has already
// consumed bytes whose cursor is ahead of Warren's ring boundary.  The reader
// is resumed after the caller releases the lock; the newly attached peer owns
// an independent reader from the paired checkpoint cursor.
func (s *Service) prepareAttach(ctx context.Context, session api.Session) (*sessionLock, func(), error) {
	// The desktop client has a shorter request timeout than the daemon's
	// command timeout. Bound the entire preparation phase independently so a
	// stalled adoption or lock cannot keep a WebSocket command
	// handler occupied forever.
	prepareContext, cancelPrepare := context.WithTimeout(ctx, s.commandTimeout())
	defer cancelPrepare()

	outputSession, err := s.ensureOutput(prepareContext, session)
	if err != nil {
		return nil, nil, err
	}
	s.outputMu.Lock()
	if outputSession.prepareLock == nil {
		outputSession.prepareLock = newSessionLock()
	}
	prepareLock := outputSession.prepareLock
	s.outputMu.Unlock()

	if err := prepareLock.LockContext(prepareContext); err != nil {
		return nil, nil, fmt.Errorf("lock attach preparation: %w", err)
	}

	var releaseOnce sync.Once
	release := func() {
		releaseOnce.Do(func() {
			s.resumeCursorOutput(session, outputSession)
			prepareLock.Unlock()
		})
	}
	// Join the shared reader before taking the broadcast lock.  A reader may be
	// blocked in a remote Read or in recordOutputWithCursor; Close unblocks it
	// and joining here establishes the exact checkpoint boundary below.
	s.stopCursorOutput(outputSession)
	lock := s.broadcastLock(session.ID)
	if err := lock.LockContext(prepareContext); err != nil {
		release()
		return nil, nil, fmt.Errorf("lock session output: %w", err)
	}
	return lock, release, nil
}

func (s *Service) attachOutputLocked(ctx context.Context, peer *wsPeer, session api.Session, anchor *output.Anchor, method string) error {
	s.lazyInit()
	s.outputMu.Lock()
	outputSession := s.outputs[session.ID]
	s.outputMu.Unlock()

	s.registerPeer(session.ID, peer)
	peer.ensureAttachment(session.ID)

	if peer.terminalStateFormat == "" {
		return errors.New("atomic terminal state format is not negotiated")
	}
	if s.cursorOutputRuntimeFor(session) == nil {
		return errors.New("ghostline atomic output runtime is unavailable")
	}
	return s.reanchorAtomicOutput(ctx, peer, session, outputSession, anchor, method)
}

// reanchorAtomicOutput sends one renderer-compatible terminal state and starts
// an independent Ghostline reader at its paired cursor. prepareAttach has
// already paused and joined the shared reader, so the state and cursor are
// paired with one exact broadcast boundary before existing output resumes.
func (s *Service) reanchorAtomicOutput(
	ctx context.Context,
	peer *wsPeer,
	session api.Session,
	outputSession *outputSession,
	anchor *output.Anchor,
	method string,
) error {
	stateContext, cancelState := context.WithTimeout(ctx, s.commandTimeout())
	var (
		format  string
		payload []byte
		cursor  ghostline.Cursor
		size    ghostline.Size
		err     error
	)
	captureStarted := time.Now()
	// Capture the Ghostline state while the shared reader is paused. The reader
	// normally keeps the Warren ring at the same cursor, but output can arrive
	// between the reader's final batch and this checkpoint. Catch that small
	// opaque-cursor gap up before calculating the protocol sequence so the
	// atomic state and the live stream share one exact boundary.
	switch peer.terminalStateFormat {
	case ghostline.AtomicStateFormat:
		runtime := s.atomicStateRuntimeFor(session)
		if runtime == nil {
			cancelState()
			return errors.New("ghostline native state runtime is unavailable")
		}
		var state ghostline.AtomicState
		state, err = runtime.AtomicState(stateContext, session.Runtime)
		format, payload, cursor, size = state.Format, state.Payload, state.Cursor, state.Size
	case terminalStateFormatANSI:
		runtime := s.cursorOutputRuntimeFor(session)
		if runtime == nil {
			cancelState()
			return errors.New("ghostline checkpoint runtime is unavailable")
		}
		var checkpoint ghostline.Checkpoint
		checkpoint, err = runtime.Checkpoint(stateContext, session.Runtime)
		format, payload, cursor = terminalStateFormatANSI, checkpoint.Replay, checkpoint.Cursor
	default:
		cancelState()
		return fmt.Errorf("unsupported terminal state format %q", peer.terminalStateFormat)
	}
	cancelState()
	captureMS := time.Since(captureStarted).Milliseconds()
	if err != nil {
		return fmt.Errorf("capture ghostline terminal state: %w", err)
	}
	if format == "" || cursor == (ghostline.Cursor{}) {
		return errors.New("ghostline returned an incomplete terminal state")
	}
	catchUpContext, cancelCatchUp := context.WithTimeout(ctx, s.commandTimeout())
	catchUpStarted := time.Now()
	catchUpSkipped, err := s.catchUpOutputCursor(catchUpContext, session, outputSession, cursor)
	catchUpMS := time.Since(catchUpStarted).Milliseconds()
	cancelCatchUp()
	if err != nil {
		return fmt.Errorf("align ghostline recovery cursor: %w", err)
	}
	outputSession.mu.Lock()
	epoch := outputSession.ring.Epoch
	upper := outputSession.ring.Upper()
	outputSession.mu.Unlock()

	defer s.logRecoveryOutcome(
		session.ID,
		method,
		branchAtomicReanchor,
		anchor,
		len(payload),
		1,
		upper,
	)

	// The size is only meaningful to a peer that negotiated it, and only when
	// Ghostline reported one; an unknown size leaves the client sizing its grid
	// from its own viewport.
	if !peer.supportsCapability(api.CapabilityTerminalSize) {
		size = ghostline.Size{}
	}
	if err := peer.enqueueAttachedSized(session.ID, epoch, upper, true, size); err != nil {
		return err
	}
	enqueueStarted := time.Now()
	if err := peer.enqueueAtomicState(
		session.ID,
		epoch,
		upper,
		format,
		payload,
	); err != nil {
		return err
	}
	enqueueMS := time.Since(enqueueStarted).Milliseconds()
	readerStarted := time.Now()
	if err := s.startPeerCursorOutput(peer, session, cursor, epoch, upper, size); err != nil {
		return err
	}
	readerMS := time.Since(readerStarted).Milliseconds()
	// Start the direct reader before releasing the presentation boundary.  Any
	// bytes produced after the checkpoint are therefore either queued before or
	// after this marker, but never lost because the reader had not been armed.
	if err := peer.enqueueSynced(session.ID, epoch, upper); err != nil {
		return err
	}
	if catchUpSkipped {
		// The ring could not be walked to the checkpoint, so the bytes between
		// its last recorded position and the checkpoint are absent from the
		// shared stream. Direct readers are unaffected (they start at the
		// checkpoint), but a peer served from the shared ring would silently
		// miss them. Re-anchoring is the in-protocol way to say so.
		s.forcePeerReanchor(session.ID, s.sharedBroadcastPeers(session.ID))
	}
	// One line that names which phase owns the attach's latency: the ghostline
	// state capture, the gap catch-up (or its skip), the encode+enqueue, or
	// arming the direct reader. `attachOutputLocked` used to report only a
	// single total, which cannot separate a slow snapshot from a slow reader.
	s.logInfo("reanchor: phases",
		"session", session.ID,
		"method", method,
		"captureMs", captureMS,
		"catchUpMs", catchUpMS,
		"catchUpSkipped", catchUpSkipped,
		"enqueueMs", enqueueMS,
		"readerMs", readerMS,
		"bytes", len(payload),
		"format", format,
	)

	return nil
}

// catchUpOutputCursor records bytes that arrived after the shared reader was
// stopped but before Ghostline captured its atomic state. Each read is bounded
// by the distance Ghostline reports to the checkpoint cursor, so it can never
// consume output produced after that boundary.
//
// When the two cursors are not comparable — a zero cursor, a generation change,
// or a reversed pair — the gap cannot be walked at all: a byte read could never
// prove it reached the checkpoint, and a session that keeps producing never
// reaches EOF either. That pair used to degrade into one byte per round trip
// until the command timeout failed the attach after its acknowledgement, which
// left the pane black. Instead the checkpoint is treated as a fresh boundary:
// the atomic state is the authoritative terminal image, and the ring continues
// from the checkpoint exactly as a fresh attach after a restart does. The
// caller is told the gap was skipped so it can re-anchor shared subscribers.
func (s *Service) catchUpOutputCursor(
	ctx context.Context,
	session api.Session,
	outputSession *outputSession,
	target ghostline.Cursor,
) (bool, error) {
	catchUpStarted := time.Now()
	caughtUpBytes := 0
	caughtUpRounds := 0
	outputSession.mu.Lock()
	from := outputSession.outputCursor
	outputSession.mu.Unlock()
	_, distanceKnown := from.Distance(target)
	// Report what the phase had to cover, and with which pair of cursors, so a
	// regression is attributable instead of showing up as a bare duration.
	defer func() {
		if caughtUpBytes == 0 {
			return
		}
		s.logInfo("reanchor: catchUp",
			"session", session.ID,
			"bytes", caughtUpBytes,
			"rounds", caughtUpRounds,
			"ms", time.Since(catchUpStarted).Milliseconds(),
			"from", from.String(),
			"target", target.String(),
			"distanceKnown", distanceKnown,
		)
	}()
	if from == target {
		return false, nil
	}
	if !distanceKnown {
		outputSession.mu.Lock()
		outputSession.outputCursor = target
		outputSession.hasOutputCursor = true
		outputSession.mu.Unlock()
		s.logWarn("reanchor: catchUpSkipped",
			"session", session.ID,
			"from", from.String(),
			"target", target.String(),
			"distanceKnown", false,
			"reason", "cursors are not comparable",
		)
		return true, nil
	}
	runtime := s.cursorOutputRuntimeFor(session)
	if runtime == nil {
		return false, errors.New("ghostline cursor runtime is unavailable")
	}
	reader, err := runtime.OpenOutput(ctx, session.Runtime, from)
	if err != nil {
		return false, fmt.Errorf("open ghostline recovery gap: %w", err)
	}
	defer reader.Close()
	buffer := make([]byte, catchUpBatchBytes)
	for {
		if reader.Cursor() == target {
			return false, nil
		}
		if err := ctx.Err(); err != nil {
			return false, err
		}
		readBuffer, closed, known := catchUpReadBuffer(buffer, reader.Cursor(), target)
		if !known {
			return false, errors.New("ghostline recovery gap stopped being comparable")
		}
		if closed {
			return false, nil
		}
		count, readErr := reader.Read(readBuffer)
		if count > 0 {
			caughtUpBytes += count
			caughtUpRounds++
			cursor := reader.Cursor()
			s.recordOutputWithCursorMode(session.ID, readBuffer[:count], &cursor, false)
			if cursor == target {
				return false, nil
			}
		}
		if readErr != nil {
			if !errors.Is(readErr, io.EOF) {
				return false, fmt.Errorf("read ghostline recovery gap: %w", readErr)
			}
			if reader.Cursor() == target {
				return false, nil
			}
			return false, fmt.Errorf("ghostline recovery gap ended before checkpoint cursor")
		}
		if count == 0 {
			return false, io.ErrNoProgress
		}
	}
}

// catchUpBatchBytes bounds one catch-up read. The gap is normally a few
// kilobytes of output that arrived between pausing the shared reader and taking
// the checkpoint, so one batch covers it in ordinary cases.
const catchUpBatchBytes = 64 * 1024

// catchUpReadBuffer sizes the next catch-up read so it cannot pass target.
//
// It returns closed when the gap is already covered, and known=false when the
// two cursors are not comparable (a zero cursor, a generation boundary, or a
// reversed pair). A caller must treat an unknown span as unrecoverable rather
// than read it one byte at a time: the span can never be proven to reach the
// checkpoint, and reading past it would duplicate bytes the live stream still
// delivers.
func catchUpReadBuffer(
	buffer []byte,
	from ghostline.Cursor,
	target ghostline.Cursor,
) (next []byte, closed bool, known bool) {
	gap, known := from.Distance(target)
	if !known {
		return nil, false, false
	}
	if gap == 0 {
		return nil, true, true
	}
	if gap < uint64(len(buffer)) {
		return buffer[:gap], false, true
	}
	return buffer, false, true
}

func (s *Service) PingOutput(sessionID string) {
	// Ghostline output readers block on the runtime stream and do not require
	// polling or an explicit wake-up.
}
