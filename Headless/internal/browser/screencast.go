package browser

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"time"
)

// frameBufferSize bounds how far a slow viewer may fall behind. One in-flight
// frame plus a small margin: a viewer that cannot keep up with a JPEG every
// 100ms is not going to catch up, and buffering more only delays what it shows.
const frameBufferSize = 2

// publishFrame hands one decoded screencast frame to every subscriber.
//
// The payload Chrome sends is base64. Decoding happens once here rather than
// per subscriber, and a subscriber that is full is skipped rather than blocked:
// the read loop must never wait on a client.
func (s *Session) publishFrame(data string) {
	payload, err := base64.StdEncoding.DecodeString(data)
	if err != nil || len(payload) == 0 {
		return
	}
	s.subscriberMu.Lock()
	s.sequence++
	sequence := s.sequence
	subscribers := make([]*frameSubscriber, 0, len(s.subscribers))
	for subscriber := range s.subscribers {
		subscribers = append(subscribers, subscriber)
	}
	s.subscriberMu.Unlock()

	// The server sink runs outside the lock: it marshals a frame for every
	// peer, which is exactly the kind of work a lock must not cover.
	if handler := s.manager.frameHandler(); handler != nil {
		handler(s.id, sequence, payload)
	}
	for _, subscriber := range subscribers {
		select {
		case subscriber.frames <- payload:
		default:
			// Dropped on purpose. The next frame carries the same page, so a
			// dropped frame costs smoothness and not correctness.
		}
	}
}

// subscribe registers a frame consumer and returns its channel plus the
// sequence the subscription started at.
func (s *Session) subscribe() (*frameSubscriber, uint64) {
	subscriber := &frameSubscriber{frames: make(chan []byte, frameBufferSize)}
	s.subscriberMu.Lock()
	defer s.subscriberMu.Unlock()
	s.subscribers[subscriber] = struct{}{}
	return subscriber, s.sequence
}

// unsubscribe removes a frame consumer.
func (s *Session) unsubscribe(subscriber *frameSubscriber) {
	s.subscriberMu.Lock()
	defer s.subscriberMu.Unlock()
	delete(s.subscribers, subscriber)
}

// dropSubscribers wakes every waiting consumer so a viewer learns the stream
// ended instead of blocking on a closed session.
func (s *Session) dropSubscribers() {
	s.subscriberMu.Lock()
	defer s.subscriberMu.Unlock()
	for subscriber := range s.subscribers {
		close(subscriber.frames)
		delete(s.subscribers, subscriber)
	}
}

// sequenceNow returns the current frame sequence.
func (s *Session) sequenceNow() uint64 {
	s.subscriberMu.Lock()
	defer s.subscriberMu.Unlock()
	return s.sequence
}

// acceptScreencastFrame reports whether a screencast frame carries a change.
//
// Chrome re-captures the surface for a still, and that capture comes back as a
// screencast frame holding the page the still just showed. Publishing it would
// paint the soft copy back over the still, so the frame is dropped when it is
// byte-for-byte what the stream already had: identical bytes are identical
// pixels, and this runs on the CDP read loop, where the remembered frame needs
// no lock.
func (s *Session) acceptScreencastFrame(data string) bool {
	if data == s.lastScreencastFrame {
		return false
	}
	s.lastScreencastFrame = data
	return true
}

// currentDeviceScaleFactor reports the density the page is rendered at.
func (s *Session) currentDeviceScaleFactor() float64 {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if s.viewportDeviceScaleFactor <= 0 {
		return defaultDeviceScaleFactor
	}
	return s.viewportDeviceScaleFactor
}

// scheduleStill asks for a still of the page as it is now.
//
// A page that keeps painting does not extend anything here — the request is
// either already in flight or already armed — so the cadence is stillSettleDelay
// for a page that just stopped and stillMinimumInterval for one that never
// does. A still is a full-resolution JPEG encode of the whole viewport, so it is
// worth taking exactly when the picture has settled and never at pointer rate.
func (s *Session) scheduleStill() {
	if s.currentDeviceScaleFactor() <= 1 {
		// At 1x a still holds exactly the pixels the screencast already
		// delivered. Encoding them a second time would buy nothing.
		return
	}
	if !s.hasFrameConsumer() {
		return
	}
	s.stillMu.Lock()
	defer s.stillMu.Unlock()
	if s.stillRunning {
		// The running capture holds an older page. One more after it is what
		// keeps a change that landed mid-capture from being missed.
		s.stillWanted = true
		return
	}
	if s.stillTimer != nil {
		return
	}
	delay := stillSettleDelay
	if earliest := s.lastStillAt.Add(stillMinimumInterval); earliest.After(time.Now().Add(delay)) {
		delay = time.Until(earliest)
	}
	s.stillTimer = time.AfterFunc(delay, s.captureStill)
}

// hasFrameConsumer reports whether anything is set up to receive frames. The
// frame handler is the Host streaming to its clients and the subscribers are a
// viewer attached to this Session directly; either one is someone watching.
func (s *Session) hasFrameConsumer() bool {
	if s.manager.frameHandler() != nil {
		return true
	}
	s.subscriberMu.Lock()
	defer s.subscriberMu.Unlock()
	return len(s.subscribers) > 0
}

// captureStill renders the page once at the display's density and publishes it
// as an ordinary frame.
//
// A capture that does not come from the surface is what the still wants: it
// does not make Chrome paint, so it is not echoed back as a screencast frame.
// A renderer that has not painted yet or whose frames are throttled refuses it,
// and then FromSurface is the only way to get an image at all.
func (s *Session) captureStill() {
	s.stillMu.Lock()
	s.stillTimer = nil
	s.stillRunning = true
	s.stillMu.Unlock()
	defer func() {
		s.stillMu.Lock()
		s.stillRunning = false
		wanted := s.stillWanted
		s.stillWanted = false
		s.stillMu.Unlock()
		if wanted {
			s.scheduleStill()
		}
	}()

	sessionID := s.pageSession()
	if sessionID == "" {
		return
	}
	s.mu.RLock()
	client := s.client
	s.mu.RUnlock()
	if client == nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	params := cdpPageCaptureScreenshotParams{Format: "jpeg", Quality: stillQuality, FromSurface: false}
	raw, err := client.Call(ctx, sessionID, cdpMethodPageCaptureScreenshot, params)
	if err != nil {
		params.FromSurface = true
		raw, err = client.Call(ctx, sessionID, cdpMethodPageCaptureScreenshot, params)
		if err != nil {
			return
		}
	}
	var result cdpScreenshotResult
	if err := json.Unmarshal(raw, &result); err != nil || result.Data == "" {
		return
	}
	// The Session can end while the capture is in flight. Publishing into a
	// closed Session is how a frame handler gets a frame for a browser that is
	// already gone.
	select {
	case <-s.done:
		return
	default:
	}
	s.stillMu.Lock()
	s.lastStillAt = time.Now()
	s.stillMu.Unlock()
	s.publishFrame(result.Data)
}
