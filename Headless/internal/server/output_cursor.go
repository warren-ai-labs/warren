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

type outputSession struct {
	mu                sync.Mutex
	sessionID         string
	runtimeName       string
	runtimeKind       string
	ring              *output.Ring
	reader            CursorOutputReader
	readerDone        chan struct{}
	readerCancel      context.CancelFunc
	outputCursor      ghostline.Cursor
	hasOutputCursor   bool
	responder         *ghostline.QueryResponder
	prepareLock       *sessionLock
	persistedSequence uint64
}

type peerOutputStream struct {
	reader CursorOutputReader
	cancel context.CancelFunc
	done   chan struct{}
}

// ensureOutput adopts a running Session. Ghostline v1 opens one caller-owned
// cursor reader. Repeating attach/adopt
// never stacks another watcher or reader.
func (s *Service) ensureOutput(ctx context.Context, session api.Session) (*outputSession, error) {
	if isACPSession(session) {
		return nil, errSessionHasNoTerminal
	}
	s.lazyInit()
	s.outputMu.Lock()
	if existing := s.outputs[session.ID]; existing != nil {
		s.outputMu.Unlock()
		if s.cursorOutputRuntimeFor(session) != nil {
			if err := s.ensureCursorOutput(session, existing); err != nil {
				return nil, err
			}
		}
		return existing, nil
	}
	s.outputMu.Unlock()

	cursorRuntime := s.cursorOutputRuntimeFor(session)
	if cursorRuntime == nil {
		// Keep an in-memory ring for lightweight embedders and unit-test
		// runtimes that implement only the base Runtime contract. Production
		// sessions are always backed by Ghostline and take the cursor path.
		o := &outputSession{
			sessionID:         session.ID,
			runtimeName:       session.Runtime,
			runtimeKind:       s.runtimeKindFor(session),
			ring:              output.NewRing(session.Epoch, s.ringCapacity(), s.ringMaxBytes(), session.Sequence),
			responder:         s.newQueryResponder(),
			prepareLock:       newSessionLock(),
			persistedSequence: session.Sequence,
		}
		s.outputMu.Lock()
		if previous := s.outputs[session.ID]; previous != nil {
			s.outputMu.Unlock()
			return previous, nil
		}
		s.outputs[session.ID] = o
		s.outputMu.Unlock()
		return o, nil
	}
	outputSession := &outputSession{
		sessionID:         session.ID,
		runtimeName:       session.Runtime,
		runtimeKind:       s.runtimeKindFor(session),
		ring:              output.NewRing(session.Epoch, s.ringCapacity(), s.ringMaxBytes(), session.Sequence),
		responder:         s.newQueryResponder(),
		prepareLock:       newSessionLock(),
		persistedSequence: session.Sequence,
		// A Host restart has no retained browser ring. The next attach must
		// replay a fresh atomic checkpoint instead of pretending that an
		// opaque Ghostline cursor is a browser byte offset.
	}
	cursor, cursorErr := ghostline.ParseCursor(session.OutputCursor)
	if cursorErr != nil {
		s.logWarn("discard invalid ghostline output cursor", "session", session.ID, "error", cursorErr)
	}
	if session.OutputCursor == "" || cursorErr != nil {
		checkpointContext, cancelCheckpoint := context.WithTimeout(ctx, s.commandTimeout())
		checkpoint, err := cursorRuntime.Checkpoint(checkpointContext, session.Runtime)
		cancelCheckpoint()
		if err != nil {
			return nil, fmt.Errorf("checkpoint ghostline output: %w", err)
		}
		cursor = checkpoint.Cursor
	}
	outputSession.outputCursor = cursor
	outputSession.hasOutputCursor = true

	s.outputMu.Lock()
	if previous := s.outputs[session.ID]; previous != nil {
		s.outputMu.Unlock()
		if err := s.ensureCursorOutput(session, previous); err != nil {
			return nil, err
		}
		return previous, nil
	}
	s.outputs[session.ID] = outputSession
	s.outputMu.Unlock()

	if session.OutputCursor == "" || cursorErr != nil {
		outputSession.mu.Lock()
		if s.Store != nil {
			if err := s.persistCursorLocked(outputSession); err != nil {
				outputSession.mu.Unlock()
				s.logWarn("persist ghostline output cursor", "session", session.ID, "error", err)
			} else {
				outputSession.mu.Unlock()
			}
		} else {
			outputSession.mu.Unlock()
		}
	}
	if err := s.ensureCursorOutput(session, outputSession); err != nil {
		s.outputMu.Lock()
		if s.outputs[session.ID] == outputSession {
			delete(s.outputs, session.ID)
		}
		s.outputMu.Unlock()
		return nil, err
	}
	return outputSession, nil
}

// ensureCursorOutput resumes a v1 reader from the last fully recorded
// Ghostline cursor. The cursor is updated only after every byte returned by a
// reader has been appended to the browser ring, so a daemon crash can at most
// replay a bounded tail and cannot lose output.
func (s *Service) ensureCursorOutput(session api.Session, outputSession *outputSession) error {
	if s.cursorOutputRuntimeFor(session) == nil {
		return nil
	}
	outputSession.mu.Lock()
	running := outputSession.reader != nil
	hasCursor := outputSession.hasOutputCursor
	outputSession.mu.Unlock()
	if running {
		return nil
	}
	if !hasCursor {
		return errors.New("ghostline output reader has no cursor")
	}
	return s.startCursorOutput(session, outputSession)
}

func (s *Service) startCursorOutput(session api.Session, outputSession *outputSession) error {
	runtime := s.cursorOutputRuntimeFor(session)
	if runtime == nil {
		return nil
	}
	outputSession.mu.Lock()
	if outputSession.reader != nil {
		outputSession.mu.Unlock()
		return nil
	}
	cursor := outputSession.outputCursor
	outputSession.mu.Unlock()

	// The reader outlives the HTTP request that happened to create or attach
	// this session. Its explicit cancellation is retained in outputSession and
	// Close always unblocks a pending remote read.
	readerContext, cancel := context.WithCancel(context.Background())
	reader, err := runtime.OpenOutput(readerContext, session.Runtime, cursor)
	if err != nil {
		cancel()
		return fmt.Errorf("open ghostline output: %w", err)
	}
	done := make(chan struct{})
	outputSession.mu.Lock()
	if outputSession.reader != nil {
		outputSession.mu.Unlock()
		cancel()
		_ = reader.Close()
		return nil
	}
	outputSession.reader = reader
	outputSession.readerDone = done
	outputSession.readerCancel = cancel
	outputSession.mu.Unlock()

	go s.readCursorOutput(session, outputSession, reader, readerContext, done)
	return nil
}

func (s *Service) readCursorOutput(session api.Session, outputSession *outputSession, reader CursorOutputReader, readerContext context.Context, done chan struct{}) {
	defer func() {
		outputSession.mu.Lock()
		if outputSession.reader == reader {
			outputSession.reader = nil
			outputSession.readerDone = nil
			outputSession.readerCancel = nil
		}
		outputSession.mu.Unlock()
		close(done)
	}()

	buffer := make([]byte, 64*1024)
	for {
		count, readErr := reader.Read(buffer)
		if count > 0 {
			data := append([]byte(nil), buffer[:count]...)
			s.recordCursorOutput(session.ID, data, reader.Cursor())
		}
		if readErr != nil {
			if !errors.Is(readErr, io.EOF) && readerContext.Err() == nil {
				s.logWarn("read ghostline output", "session", session.ID, "error", readErr)
			}
			return
		}
		if count == 0 {
			s.logWarn("read ghostline output", "session", session.ID, "error", io.ErrNoProgress)
			return
		}
	}
}

// reservePeerCursorOutput removes and joins an older reader, then marks the
// subscription as direct before its snapshot is captured. Shared ring
// broadcasts skip reserved subscriptions, so resize redraws and other bytes
// produced before the snapshot cannot leak ahead of the replacement state.
func (s *Service) reservePeerCursorOutput(peer *wsPeer, sessionID string) {
	s.stopPeerCursorOutput(peer, sessionID, true)
	s.outputMu.Lock()
	streams := s.peerOutputs[peer]
	if streams == nil {
		streams = map[string]*peerOutputStream{}
		s.peerOutputs[peer] = streams
	}
	streams[sessionID] = nil
	s.outputMu.Unlock()
}

func (s *Service) startPeerCursorOutput(
	peer *wsPeer,
	session api.Session,
	cursor ghostline.Cursor,
	epoch, sequence uint64,
) error {
	runtime := s.cursorOutputRuntimeFor(session)
	if runtime == nil {
		return errors.New("ghostline cursor runtime is unavailable")
	}
	readerContext, cancel := context.WithCancel(context.Background())
	reader, err := runtime.OpenOutput(readerContext, session.Runtime, cursor)
	if err != nil {
		cancel()
		return fmt.Errorf("open peer ghostline output: %w", err)
	}
	stream := &peerOutputStream{
		reader: reader,
		cancel: cancel,
		done:   make(chan struct{}),
	}
	s.outputMu.Lock()
	streams := s.peerOutputs[peer]
	current, reserved := streams[session.ID]
	if !reserved || current != nil {
		s.outputMu.Unlock()
		cancel()
		_ = reader.Close()
		return errors.New("terminal output subscription changed during recovery")
	}
	streams[session.ID] = stream
	s.outputMu.Unlock()

	go s.readPeerCursorOutput(peer, session.ID, reader, readerContext, stream, epoch, sequence)
	return nil
}

func (s *Service) readPeerCursorOutput(
	peer *wsPeer,
	sessionID string,
	reader CursorOutputReader,
	readerContext context.Context,
	stream *peerOutputStream,
	epoch, sequence uint64,
) {
	defer close(stream.done)
	buffer := make([]byte, 64*1024)
	for {
		count, readErr := reader.Read(buffer)
		if count > 0 {
			payload := append([]byte(nil), buffer[:count]...)
			encoded, encodeErr := output.EncodeOutput(sessionID, epoch, sequence, payload)
			if encodeErr != nil || !peer.enqueueBinary(encoded) {
				return
			}
			sequence += uint64(count)
		}
		if readErr != nil {
			// Runtime teardown can close a reader before Service.stopOutput gets
			// to detach the peer (session.delete and workspace cleanup both kill
			// the runtime first). io.ErrClosedPipe is therefore a normal reader
			// lifecycle result, just like EOF; treating it as a transport failure
			// closes the WebSocket before the mutation response can be delivered.
			// Other errors still close the peer so a genuinely broken output
			// stream cannot leave the client connected to a silent subscription.
			if !errors.Is(readErr, io.EOF) && !errors.Is(readErr, io.ErrClosedPipe) && readerContext.Err() == nil {
				s.logWarn("read peer ghostline output", "session", sessionID, "error", readErr)
				peer.closeWithReason("runtime_output_error")
			}
			return
		}
		if count == 0 {
			s.logWarn("read peer ghostline output", "session", sessionID, "error", io.ErrNoProgress)
			peer.closeWithReason("runtime_output_no_progress")
			return
		}
	}
}

// stopPeerCursorOutput removes a direct subscription before stopping its
// reader. Teardown paths do not wait because they may be called synchronously
// from that reader's outbound-overflow path; replacement recovery waits so no
// stale frame can enqueue after the next snapshot. The wait is bounded so a
// stale peer reader that does not observe Close promptly cannot stall a
// rapid tab switch (see stopCursorOutputWithin).
func (s *Service) stopPeerCursorOutput(peer *wsPeer, sessionID string, wait bool) {
	s.outputMu.Lock()
	streams := s.peerOutputs[peer]
	stream, exists := streams[sessionID]
	if exists {
		delete(streams, sessionID)
		if len(streams) == 0 {
			delete(s.peerOutputs, peer)
		}
	}
	s.outputMu.Unlock()
	if !exists || stream == nil {
		return
	}
	stream.cancel()
	_ = stream.reader.Close()
	if wait {
		select {
		case <-stream.done:
		case <-time.After(2 * time.Second):
			s.logWarn("stopPeerCursorOutput join timed out", "session", sessionID, "timeoutMs", int64(2000))
		}
	}
}

// stopCursorOutput closes and joins a caller-owned v1 reader. It intentionally
// runs before an attach obtains the broadcast lock: a reader can be waiting to
// publish output under that lock, and reversing the order would deadlock the
// checkpoint boundary.
//
// The join is bounded: a ghostline reader can be blocked inside a remote Read
// that does not observe Close promptly (for example when the ghostline server
// stops answering output-read RPCs). Without a bound, a rapid workspace/tab
// switch would hang the new subscribe behind the stale reader forever, leaving
// the target pane black. On timeout we record a warning and proceed; the stale
// reader is closed and will be replaced by ensureCursorOutput on resume.
func (s *Service) stopCursorOutput(outputSession *outputSession) {
	s.stopCursorOutputWithin(outputSession, 2*time.Second, "subscribe/attach")
}

func (s *Service) stopCursorOutputWithin(outputSession *outputSession, timeout time.Duration, caller string) {
	if outputSession == nil {
		return
	}
	outputSession.mu.Lock()
	reader := outputSession.reader
	done := outputSession.readerDone
	cancel := outputSession.readerCancel
	if cancel != nil {
		cancel()
	}
	if reader != nil {
		_ = reader.Close()
	}
	outputSession.mu.Unlock()
	if done == nil {
		return
	}
	select {
	case <-done:
	case <-time.After(timeout):
		s.logWarn("stopCursorOutput join timed out", "caller", caller, "timeoutMs", timeout.Milliseconds())
	}
}

func (s *Service) resumeCursorOutput(session api.Session, outputSession *outputSession) {
	if err := s.ensureCursorOutput(session, outputSession); err != nil {
		s.logWarn("resume ghostline output", "session", session.ID, "error", err)
	}
}
