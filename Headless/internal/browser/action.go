package browser

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

// Defaults for the action surface. They are deliberately explicit so a caller
// never has to guess what a zero value means.
const (
	DefaultScreenshotQuality = 80
	DefaultSnapshotMaxNodes  = 300
	DefaultConsoleLimit      = 100
	DefaultWaitTimeoutMs     = 10000
)

// errNoPage reports that Chromium has no page target to act on. This is a
// Session-state error, not a caller error: it means the page was closed.
var errNoPage = errors.New("browser: no active page")

// Perform executes one normalized action and reports its outcome.
//
// Every action returns the page URL and title it left behind, because an agent's
// next decision almost always depends on where it ended up. An action that
// changed nothing still answers with the current state rather than an empty
// result.
func (s *Session) Perform(ctx context.Context, action api.BrowserAction) (api.BrowserActionResult, error) {
	if action.Action == "" {
		return api.BrowserActionResult{}, errors.New("browser: action is required")
	}
	sessionID := s.pageSession()
	if sessionID == "" {
		return api.BrowserActionResult{}, errNoPage
	}
	// One action may issue several CDP calls; the context bounds the whole
	// sequence so a caller's deadline is respected end to end.
	timeout := actionTimeout(action.TimeoutMs)
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	result := api.BrowserActionResult{Action: action.Action}
	var (
		payload map[string]any
		err     error
	)
	switch action.Action {
	case api.BrowserActionNavigate:
		payload, err = s.actNavigate(ctx, sessionID, action)
	case api.BrowserActionBack:
		payload, err = s.actHistory(ctx, sessionID, -1)
	case api.BrowserActionForward:
		payload, err = s.actHistory(ctx, sessionID, 1)
	case api.BrowserActionReload:
		payload, err = s.actReload(ctx, sessionID, action)
	case api.BrowserActionClick:
		payload, err = s.actClick(ctx, sessionID, action)
	case api.BrowserActionHover:
		payload, err = s.actHover(ctx, sessionID, action)
	case api.BrowserActionType:
		payload, err = s.actType(ctx, sessionID, action)
	case api.BrowserActionPress:
		payload, err = s.actPress(ctx, sessionID, action)
	case api.BrowserActionSelect:
		payload, err = s.actSelect(ctx, sessionID, action)
	case api.BrowserActionScroll:
		payload, err = s.actScroll(ctx, sessionID, action)
	case api.BrowserActionWait:
		payload, err = s.actWait(ctx, sessionID, action)
	case api.BrowserActionScreenshot:
		payload, err = s.actScreenshot(ctx, sessionID, action)
	case api.BrowserActionSnapshot:
		payload, err = s.actSnapshot(ctx, sessionID, action)
	case api.BrowserActionEvaluate:
		payload, err = s.actEvaluate(ctx, sessionID, action)
	case api.BrowserActionTabsList:
		payload, err = s.actTabsList(ctx)
	case api.BrowserActionTabsNew:
		payload, err = s.actTabsNew(ctx, action)
	case api.BrowserActionTabsClose:
		payload, err = s.actTabsClose(ctx, action)
	case api.BrowserActionTabsSelect:
		payload, err = s.actTabsSelect(ctx, action)
	case api.BrowserActionViewport:
		payload, err = s.actViewport(ctx, sessionID, action)
	case api.BrowserActionCookies:
		payload, err = s.actCookies(ctx, sessionID)
	case api.BrowserActionConsole:
		payload, err = s.actConsole(action)
	default:
		return api.BrowserActionResult{}, fmt.Errorf("browser: unknown action %q", action.Action)
	}
	if err != nil {
		return api.BrowserActionResult{Action: action.Action}, err
	}
	result.Result = payload
	// A gesture cannot change the document the tab is on, and the URL/title echo
	// costs an extra Runtime.evaluate. That is affordable once per agent command
	// and not on a pointer-rate path: the viewer sends a wheel action for every
	// frame of a scroll, and each one would otherwise pay for a round trip whose
	// answer it already has.
	if !isGesture(action.Action) {
		result.URL, result.Title = s.currentPageState(ctx, sessionID)
	}
	return result, nil
}

// isGesture reports whether an action only moves the pointer or the scroll
// position. Such an action cannot navigate, so the URL and title it would report
// are the ones the caller already has.
func isGesture(action string) bool {
	switch action {
	case api.BrowserActionHover, api.BrowserActionScroll:
		return true
	default:
		return false
	}
}

// actionTimeout resolves the per-action bound. Zero means the default; an
// explicit value is clamped to a sane range so a caller cannot pass 0 and get an
// immediately expired context, or 1<<40 and hold the Host for a day.
func actionTimeout(timeoutMs int) time.Duration {
	if timeoutMs <= 0 {
		return defaultCDPTimeout
	}
	if timeoutMs > 600000 {
		timeoutMs = 600000
	}
	return time.Duration(timeoutMs) * time.Millisecond
}

func (s *Session) actNavigate(ctx context.Context, sessionID string, action api.BrowserAction) (map[string]any, error) {
	url := strings.TrimSpace(action.URL)
	if url == "" {
		return nil, errors.New("browser: navigate requires a url")
	}
	if !strings.Contains(url, "://") {
		url = "https://" + url
	}
	s.resetLoadGate()
	raw, err := s.client.Call(ctx, sessionID, cdpMethodPageNavigate, cdpPageNavigateParams{URL: url})
	if err != nil {
		return nil, err
	}
	var navigated struct {
		ErrorText string `json:"errorText"`
		FrameID   string `json:"frameId"`
	}
	// A navigate that Chrome refused reports the reason in the result rather
	// than as a protocol error, so it has to be read.
	_ = json.Unmarshal(raw, &navigated)
	if navigated.ErrorText != "" {
		return nil, fmt.Errorf("browser: navigate to %s: %s", url, navigated.ErrorText)
	}
	s.awaitLoad(ctx, waitDuration(action.WaitUntil))
	_ = s.refreshHistory(ctx, sessionID)
	return map[string]any{"url": url}, nil
}

func (s *Session) actReload(ctx context.Context, sessionID string, action api.BrowserAction) (map[string]any, error) {
	s.resetLoadGate()
	if _, err := s.client.Call(ctx, sessionID, cdpMethodPageReload, cdpPageReloadParams{IgnoreCache: action.Hard}); err != nil {
		return nil, err
	}
	s.awaitLoad(ctx, waitDuration(action.WaitUntil))
	_ = s.refreshHistory(ctx, sessionID)
	return map[string]any{"hard": action.Hard}, nil
}

// actHistory moves through the back/forward stack.
//
// The index is resolved locally from the mirrored history, which avoids a
// round trip to ask whether the move is possible: an agent asking to go back on
// the first page deserves "you cannot", not a timeout.
func (s *Session) actHistory(ctx context.Context, sessionID string, delta int) (map[string]any, error) {
	if err := s.refreshHistory(ctx, sessionID); err != nil {
		return nil, err
	}
	s.mu.RLock()
	index := s.historyIndex
	entries := len(s.history)
	s.mu.RUnlock()
	target := index + delta
	if target < 0 || target >= entries {
		return nil, fmt.Errorf("browser: no history entry in that direction (index %d of %d)", index, entries)
	}
	s.mu.RLock()
	entryID := s.history[target].ID
	url := s.history[target].URL
	s.mu.RUnlock()
	s.resetLoadGate()
	if _, err := s.client.Call(ctx, sessionID, cdpMethodPageNavigateHistory, map[string]any{"entryId": entryID}); err != nil {
		return nil, err
	}
	s.awaitLoad(ctx, waitDuration(""))
	s.mu.Lock()
	s.historyIndex = target
	s.mu.Unlock()
	return map[string]any{"url": url, "index": target}, nil
}

// refreshHistory mirrors Chrome's back/forward stack.
func (s *Session) refreshHistory(ctx context.Context, sessionID string) error {
	raw, err := s.client.Call(ctx, sessionID, cdpMethodPageGetNavigationHistory, nil)
	if err != nil {
		return err
	}
	var history cdpNavigationHistoryResult
	if err := json.Unmarshal(raw, &history); err != nil {
		return fmt.Errorf("decode Page.getNavigationHistory: %w", err)
	}
	s.mu.Lock()
	s.history = history.Entries
	s.historyIndex = history.CurrentIndex
	s.mu.Unlock()
	return nil
}

func (s *Session) actClick(ctx context.Context, sessionID string, action api.BrowserAction) (map[string]any, error) {
	point, selector, err := s.resolvePoint(ctx, sessionID, action)
	if err != nil {
		return nil, err
	}
	if err := s.dispatchMouse(ctx, sessionID, cdpInputMouseEventParams{Type: "mouseMoved", X: point[0], Y: point[1]}); err != nil {
		return nil, err
	}
	if err := s.dispatchMouse(ctx, sessionID, cdpInputMouseEventParams{Type: "mousePressed", X: point[0], Y: point[1], Button: "left", Buttons: 1, ClickCount: 1}); err != nil {
		return nil, err
	}
	if err := s.dispatchMouse(ctx, sessionID, cdpInputMouseEventParams{Type: "mouseReleased", X: point[0], Y: point[1], Button: "left", Buttons: 1, ClickCount: 1}); err != nil {
		return nil, err
	}
	return map[string]any{"selector": selector, "x": point[0], "y": point[1]}, nil
}

func (s *Session) actHover(ctx context.Context, sessionID string, action api.BrowserAction) (map[string]any, error) {
	point, selector, err := s.resolvePoint(ctx, sessionID, action)
	if err != nil {
		return nil, err
	}
	if err := s.dispatchMouse(ctx, sessionID, cdpInputMouseEventParams{Type: "mouseMoved", X: point[0], Y: point[1]}); err != nil {
		return nil, err
	}
	return map[string]any{"selector": selector, "x": point[0], "y": point[1]}, nil
}

// actType types text into an element.
//
// The text is inserted with Input.insertText rather than one key event per
// character. insertText goes through the renderer's normal input path, which is
// what makes it work with controlled inputs and with IME composition, while
// per-character key events do not. A key press that matters (Enter, Tab) is a
// separate press action on purpose.
func (s *Session) actType(ctx context.Context, sessionID string, action api.BrowserAction) (map[string]any, error) {
	point, selector, err := s.resolvePoint(ctx, sessionID, action)
	if err != nil {
		return nil, err
	}
	focused, err := s.focusTarget(ctx, sessionID, action, point)
	if err != nil {
		return nil, err
	}
	if action.ClearFirst {
		if err := s.evaluate(ctx, sessionID, clearFieldExpression(action.Selector), &struct{}{}); err != nil {
			return nil, err
		}
	}
	if action.Value != "" {
		if _, err := s.client.Call(ctx, sessionID, "Input.insertText", map[string]any{"text": action.Value}); err != nil {
			return nil, err
		}
	}
	if action.DelayMs > 0 {
		// A per-keystroke delay exists so a page's debounced search sees the
		// typing. The delay is applied once after the insert because insertText
		// is one atomic input event; a caller that needs real keystroke timing
		// uses press per key.
		select {
		case <-time.After(time.Duration(action.DelayMs) * time.Millisecond):
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
	return map[string]any{"typed": len(action.Value), "cleared": action.ClearFirst, "selector": selector, "focused": focused}, nil
}

// focusTarget moves focus onto the target of a type action and reports whether
// the page accepted it.
//
// A page is free to ignore focus() — a component that only listens for pointer
// events, or a field inside a shadow root — so the click fallback is not
// defensive padding: it is the path those pages actually take.
func (s *Session) focusTarget(ctx context.Context, sessionID string, action api.BrowserAction, point [2]float64) (bool, error) {
	var focused struct {
		Focused bool `json:"focused"`
	}
	if err := s.evaluate(ctx, sessionID, focusExpression(action.Selector), &focused); err == nil && focused.Focused {
		return true, nil
	}
	if err := s.dispatchMouse(ctx, sessionID, cdpInputMouseEventParams{Type: "mouseMoved", X: point[0], Y: point[1]}); err != nil {
		return false, err
	}
	for _, eventType := range []string{"mousePressed", "mouseReleased"} {
		if err := s.dispatchMouse(ctx, sessionID, cdpInputMouseEventParams{Type: eventType, X: point[0], Y: point[1], Button: "left", Buttons: 1, ClickCount: 1}); err != nil {
			return false, err
		}
	}
	return false, nil
}

func (s *Session) actPress(ctx context.Context, sessionID string, action api.BrowserAction) (map[string]any, error) {
	key := strings.TrimSpace(action.Value)
	if key == "" {
		return nil, errors.New("browser: press requires a value naming the key")
	}
	spec, ok := keySpecs[key]
	if !ok {
		spec = keySpec{Code: key, VirtualKey: virtualKeyForName(key)}
	}
	if err := s.dispatchKey(ctx, sessionID, spec, "keyDown", ""); err != nil {
		return nil, err
	}
	// A printable key needs a char event or the text never reaches the field.
	if spec.Text != "" {
		if err := s.dispatchKey(ctx, sessionID, spec, "char", spec.Text); err != nil {
			return nil, err
		}
	}
	if err := s.dispatchKey(ctx, sessionID, spec, "keyUp", ""); err != nil {
		return nil, err
	}
	return map[string]any{"key": key}, nil
}

// actSelect chooses options in a <select>.
//
// The value is assigned through the DOM and then the change and input events
// are dispatched by hand, because a framework's controlled select listens for
// them and a raw value assignment is invisible to it.
func (s *Session) actSelect(ctx context.Context, sessionID string, action api.BrowserAction) (map[string]any, error) {
	values := action.Values
	if len(values) == 0 && strings.TrimSpace(action.Value) != "" {
		values = []string{strings.TrimSpace(action.Value)}
	}
	if len(values) == 0 {
		return nil, errors.New("browser: select requires at least one value")
	}
	selector := strings.TrimSpace(action.Selector)
	if selector == "" {
		return nil, errors.New("browser: select requires a selector")
	}
	var outcome struct {
		Selected []string `json:"selected"`
		Found    bool     `json:"found"`
	}
	if err := s.evaluate(ctx, sessionID, selectExpression(selector, values), &outcome); err != nil {
		return nil, err
	}
	if !outcome.Found {
		return nil, fmt.Errorf("browser: no element matches %s", selector)
	}
	return map[string]any{"selector": selector, "values": outcome.Selected}, nil
}

func (s *Session) actScroll(ctx context.Context, sessionID string, action api.BrowserAction) (map[string]any, error) {
	// A selector means "scroll this element into view"; a delta means "scroll
	// the page by this much". Both are things an agent asks for, and conflating
	// them would make one of them impossible.
	if strings.TrimSpace(action.Selector) != "" || strings.TrimSpace(action.Text) != "" {
		var found struct {
			Found bool `json:"found"`
		}
		if err := s.evaluate(ctx, sessionID, scrollIntoViewExpression(action.Selector, action.Text), &found); err != nil {
			return nil, err
		}
		if !found.Found {
			return nil, fmt.Errorf("browser: no element matches %q", firstNonEmpty(action.Selector, action.Text))
		}
		return map[string]any{"scrolledTo": firstNonEmpty(action.Selector, action.Text)}, nil
	}
	if action.DX == 0 && action.DY == 0 {
		return map[string]any{"scrolled": false}, nil
	}
	// A client dragging the viewer window resizes the page from another
	// goroutine, so the viewport is read under the lock rather than in the clear.
	viewport := s.currentViewport()
	// The deltas carry the sign a pointer event hands a page: a positive DY
	// scrolls down. CDP takes the same convention, so a viewer that forwards
	// what it reads needs no sign flip — and a flip is exactly what made the
	// embedded browser scroll the wrong way.
	//
	// A wheel that names its coordinates scrolls where the user pointed. Falling
	// back to the centre keeps the agent's bare `scroll --dy` meaningful.
	x, y := float64(viewport.Width)/2, float64(viewport.Height)/2
	if action.X != nil && action.Y != nil {
		x, y = *action.X, *action.Y
	}
	if err := s.dispatchMouse(ctx, sessionID, cdpInputMouseEventParams{
		Type:   "mouseWheel",
		X:      x,
		Y:      y,
		DeltaX: float64(action.DX),
		DeltaY: float64(action.DY),
	}); err != nil {
		return nil, err
	}
	return map[string]any{"dx": action.DX, "dy": action.DY}, nil
}

func (s *Session) actWait(ctx context.Context, sessionID string, action api.BrowserAction) (map[string]any, error) {
	if strings.TrimSpace(action.Selector) == "" && strings.TrimSpace(action.Text) == "" && strings.TrimSpace(action.URL) == "" {
		// A bare wait is a sleep. It is in the action set because an agent that
		// just navigated sometimes needs the page to settle before snapshotting.
		select {
		case <-time.After(waitDuration("")):
		case <-ctx.Done():
			return nil, ctx.Err()
		}
		return map[string]any{"waitedMs": int(waitDuration("").Milliseconds())}, nil
	}
	deadline := time.Now().Add(waitDuration(action.State))
	state := strings.TrimSpace(action.State)
	if state == "" {
		state = "visible"
	}
	for time.Now().Before(deadline) {
		var outcome struct {
			Ready bool `json:"ready"`
		}
		if s.evaluate(ctx, sessionID, waitExpression(action.Selector, action.Text, action.URL, state), &outcome) == nil && outcome.Ready {
			return map[string]any{"state": state, "ready": true}, nil
		}
		select {
		case <-time.After(150 * time.Millisecond):
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
	return nil, fmt.Errorf("browser: timed out waiting for %s state %q", firstNonEmpty(action.Selector, action.Text, action.URL), state)
}

func (s *Session) actScreenshot(ctx context.Context, sessionID string, action api.BrowserAction) (map[string]any, error) {
	// The saved artifact is PNG and the live stream is JPEG, on purpose. A frame
	// the viewer paints is bandwidth, so it is lossy; the file an agent writes
	// and then reads back is evidence, so it is lossless. Quality is a JPEG
	// concept and is dropped here rather than silently ignored.
	format := "png"
	if action.Format != "" {
		format = strings.ToLower(strings.TrimSpace(action.Format))
	}
	switch format {
	case "png", "jpeg", "jpg", "webp":
	default:
		return nil, fmt.Errorf("browser: unsupported screenshot format %q", action.Format)
	}
	params := cdpPageCaptureScreenshotParams{
		Format: format,
		// FromSurface is required whenever the page has not painted since the
		// last capture; without it Chrome answers with an error rather than an
		// image, which would make a screenshot after a fast navigation fail.
		FromSurface: true,
	}
	if format != "png" {
		quality := action.Quality
		if quality <= 0 || quality > 100 {
			quality = DefaultScreenshotQuality
		}
		params.Quality = quality
	}
	if action.FullPage {
		params.CaptureBeyondViewport = true
	}
	raw, err := s.client.Call(ctx, sessionID, cdpMethodPageCaptureScreenshot, params)
	if err != nil {
		return nil, err
	}
	var captured cdpScreenshotResult
	if err := json.Unmarshal(raw, &captured); err != nil {
		return nil, fmt.Errorf("decode Page.captureScreenshot: %w", err)
	}
	if captured.Data == "" {
		return nil, errors.New("browser: captureScreenshot returned no image")
	}
	payload, err := base64.StdEncoding.DecodeString(captured.Data)
	if err != nil {
		return nil, fmt.Errorf("decode screenshot payload: %w", err)
	}
	result := map[string]any{"bytes": len(payload), "format": format, "fullPage": action.FullPage}
	if format != "png" {
		result["quality"] = params.Quality
	}
	if path := strings.TrimSpace(action.Path); path != "" {
		if err := writeScreenshot(path, payload); err != nil {
			return nil, err
		}
		result["path"] = path
		return result, nil
	}
	result["data"] = captured.Data
	return result, nil
}

// writeScreenshot writes a captured frame to the caller's path.
//
// The path is trusted: it is a Host-side filesystem path supplied by the agent
// that owns this Session, and the whole point of Path is that the agent decides
// where its own verification artifact lives.
func writeScreenshot(path string, payload []byte) error {
	expanded := path
	if strings.HasPrefix(expanded, "~/") {
		home, err := os.UserHomeDir()
		if err != nil {
			return err
		}
		expanded = filepath.Join(home, expanded[2:])
	}
	if dir := filepath.Dir(expanded); dir != "" && dir != "." {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return fmt.Errorf("create screenshot directory: %w", err)
		}
	}
	if err := os.WriteFile(expanded, payload, 0o644); err != nil {
		return fmt.Errorf("write screenshot: %w", err)
	}
	return nil
}

func (s *Session) actSnapshot(ctx context.Context, sessionID string, action api.BrowserAction) (map[string]any, error) {
	maxNodes := action.MaxNodes
	if maxNodes <= 0 {
		maxNodes = DefaultSnapshotMaxNodes
	}
	var snapshot struct {
		Nodes     []api.BrowserDomNode `json:"nodes"`
		URL       string               `json:"url"`
		Title     string               `json:"title"`
		Truncated bool                 `json:"truncated"`
	}
	if err := s.evaluate(ctx, sessionID, snapshotExpression(maxNodes, action.InteractiveOnly), &snapshot); err != nil {
		return nil, err
	}
	return map[string]any{
		"nodes":     snapshot.Nodes,
		"nodeCount": len(snapshot.Nodes),
		"url":       snapshot.URL,
		"title":     snapshot.Title,
		"truncated": len(snapshot.Nodes) >= maxNodes,
	}, nil
}

func (s *Session) actEvaluate(ctx context.Context, sessionID string, action api.BrowserAction) (map[string]any, error) {
	expression := strings.TrimSpace(action.Expression)
	if expression == "" {
		return nil, errors.New("browser: evaluate requires an expression")
	}
	value, err := s.evaluateRaw(ctx, sessionID, expression)
	if err != nil {
		return nil, err
	}
	return map[string]any{"value": value}, nil
}

func (s *Session) actTabsList(ctx context.Context) (map[string]any, error) {
	raw, err := s.client.Call(ctx, "", cdpMethodTargetGetTargets, nil)
	if err != nil {
		return nil, err
	}
	var targets cdpTargets
	if err := json.Unmarshal(raw, &targets); err != nil {
		return nil, fmt.Errorf("decode Target.getTargets: %w", err)
	}
	active := s.pageTarget()
	tabs := make([]api.BrowserTab, 0, len(targets.TargetInfos))
	for _, target := range targets.TargetInfos {
		if target.Type != "page" {
			continue
		}
		tabs = append(tabs, api.BrowserTab{
			ID:     target.TargetID,
			URL:    target.URL,
			Title:  target.Title,
			Active: target.TargetID == active,
		})
	}
	return map[string]any{"tabs": tabs}, nil
}

func (s *Session) actTabsNew(ctx context.Context, action api.BrowserAction) (map[string]any, error) {
	url := strings.TrimSpace(action.URL)
	if url == "" {
		url = "about:blank"
	} else if !strings.Contains(url, "://") {
		url = "https://" + url
	}
	raw, err := s.client.Call(ctx, "", cdpMethodTargetCreateTarget, cdpTargetCreateParams{URL: url})
	if err != nil {
		return nil, err
	}
	var created cdpTargetCreateResult
	if err := json.Unmarshal(raw, &created); err != nil {
		return nil, fmt.Errorf("decode Target.createTarget: %w", err)
	}
	if err := s.switchToTarget(ctx, created.TargetID); err != nil {
		return nil, err
	}
	return map[string]any{"tabId": created.TargetID, "url": url}, nil
}

func (s *Session) actTabsClose(ctx context.Context, action api.BrowserAction) (map[string]any, error) {
	targetID := strings.TrimSpace(action.TabID)
	if targetID == "" {
		return nil, errors.New("browser: tabs.close requires a tabId")
	}
	if targetID == s.pageTarget() {
		return nil, errors.New("browser: cannot close the active tab; select another tab first")
	}
	if _, err := s.client.Call(ctx, "", cdpMethodTargetCloseTarget, cdpTargetCloseParams{TargetID: targetID}); err != nil {
		return nil, err
	}
	return map[string]any{"closed": targetID}, nil
}

func (s *Session) actTabsSelect(ctx context.Context, action api.BrowserAction) (map[string]any, error) {
	targetID := strings.TrimSpace(action.TabID)
	if targetID == "" {
		return nil, errors.New("browser: tabs.select requires a tabId")
	}
	if targetID == s.pageTarget() {
		return map[string]any{"tabId": targetID, "alreadyActive": true}, nil
	}
	if err := s.switchToTarget(ctx, targetID); err != nil {
		return nil, err
	}
	return map[string]any{"tabId": targetID}, nil
}

// switchToTarget makes one tab the active page for every later action.
//
// The old page session is detached and the new one attached, because Warren
// holds exactly one active page per Session: the alternative is a set of live
// page sessions that all receive screencast frames, which a single viewer
// cannot render and an agent cannot reason about.
func (s *Session) switchToTarget(ctx context.Context, targetID string) error {
	previousSession := s.pageSession()
	if previousSession != "" {
		if _, err := s.client.Call(ctx, "", cdpMethodTargetDetachFromTarget, map[string]any{"sessionId": previousSession}); err != nil {
			// A target that already went away is not an error: the tab was
			// closed from the page itself.
			if !strings.Contains(err.Error(), "Session not found") {
				return err
			}
		}
	}
	return s.attachPage(ctx, s.client, targetID)
}

func (s *Session) actViewport(ctx context.Context, sessionID string, action api.BrowserAction) (map[string]any, error) {
	viewport := s.currentViewport()
	if action.Width > 0 {
		viewport.Width = action.Width
	}
	if action.Height > 0 {
		viewport.Height = action.Height
	}
	deviceScaleFactor := s.currentDeviceScaleFactor()
	if action.DeviceScaleFactor > 0 {
		deviceScaleFactor = clampDeviceScaleFactor(action.DeviceScaleFactor)
	}
	if viewport == s.viewport && deviceScaleFactor == s.viewportDeviceScaleFactor {
		return map[string]any{"width": viewport.Width, "height": viewport.Height, "changed": false}, nil
	}
	if err := s.resizeViewport(ctx, viewport, deviceScaleFactor); err != nil {
		return nil, err
	}
	return map[string]any{"width": viewport.Width, "height": viewport.Height, "changed": true}, nil
}

// Resize sets the page size in CSS pixels and restarts the screencast at the
// new size.
//
// It is the entry point for a client dragging the viewer window, which arrives
// as an ordinary terminal resize carrying a pixel size rather than an action.
// The screencast is restarted because Chrome keeps encoding at the dimensions
// it was started with and scales the result, so a viewer that is not resized
// this way shows a stretched page after a window drag. The display density is
// whatever the viewer last asked for: a window drag says nothing about it.
func (s *Session) Resize(ctx context.Context, viewport api.BrowserViewport) error {
	return s.resizeViewport(ctx, viewport, s.currentDeviceScaleFactor())
}

// resizeViewport applies a page size and display density together, because both
// come from the same viewer and either one alone leaves the other stale.
func (s *Session) resizeViewport(ctx context.Context, viewport api.BrowserViewport, deviceScaleFactor float64) error {
	s.mu.RLock()
	unchanged := viewport == s.viewport && deviceScaleFactor == s.viewportDeviceScaleFactor
	client := s.client
	s.mu.RUnlock()
	if unchanged {
		return nil
	}
	if client == nil {
		return errNoPage
	}
	sessionID := s.pageSession()
	if sessionID == "" {
		return errNoPage
	}
	if err := s.applyViewport(ctx, sessionID, viewport, deviceScaleFactor); err != nil {
		return err
	}
	s.mu.Lock()
	s.viewport = viewport
	s.viewportDeviceScaleFactor = deviceScaleFactor
	s.mu.Unlock()
	// The screencast restarts so frames come back at the new size instead of the
	// old one scaled. A stop that fails is not worth a retry — the restart below
	// is what sets the size — but a start that fails leaves the viewer black, so
	// that one is the caller's problem to see.
	if _, err := client.Call(ctx, sessionID, cdpMethodPageStopScreencast, nil); err != nil {
		return err
	}
	if err := s.startScreencast(ctx, sessionID); err != nil {
		return err
	}
	// The new size is worth a still of its own: the frame the viewer was drawing
	// carries the old layout, and the page may well not paint again.
	s.scheduleStill()
	return nil
}

// currentViewport reports the page size under the lock. A client resize writes
// it from the per-session worker, so an action reading it in the clear would
// race with a window drag.
func (s *Session) currentViewport() api.BrowserViewport {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.viewport
}

func (s *Session) actCookies(ctx context.Context, sessionID string) (map[string]any, error) {
	raw, err := s.client.Call(ctx, sessionID, cdpMethodNetworkGetCookies, nil)
	if err != nil {
		return nil, err
	}
	var cookies cdpNetworkCookiesResult
	if err := json.Unmarshal(raw, &cookies); err != nil {
		return nil, fmt.Errorf("decode Network.getCookies: %w", err)
	}
	projected := make([]api.BrowserCookie, 0, len(cookies.Cookies))
	for _, cookie := range cookies.Cookies {
		projected = append(projected, api.BrowserCookie{
			Name:     cookie.Name,
			Value:    cookie.Value,
			Domain:   cookie.Domain,
			Path:     cookie.Path,
			Expires:  cookie.Expires,
			HTTPOnly: cookie.HTTPOnly,
			Secure:   cookie.Secure,
			SameSite: cookie.SameSite,
		})
	}
	return map[string]any{"cookies": projected}, nil
}

func (s *Session) actConsole(action api.BrowserAction) (map[string]any, error) {
	limit := action.Limit
	if limit <= 0 {
		limit = DefaultConsoleLimit
	}
	entries := s.consoleEntries(strings.TrimSpace(action.Level), limit)
	return map[string]any{"entries": entries, "count": len(entries)}, nil
}

// currentPageState reads the active tab's URL and title from the page itself.
// Target.getTargets lags behind a client-side navigation, which would make an
// action report a URL the page already left.
func (s *Session) currentPageState(ctx context.Context, sessionID string) (string, string) {
	var state struct {
		URL   string `json:"url"`
		Title string `json:"title"`
	}
	if err := s.evaluate(ctx, sessionID, "JSON.stringify({url: location.href, title: document.title})", &state); err != nil {
		return "", ""
	}
	s.setPageState(state.URL, state.Title)
	return state.URL, state.Title
}

// evaluateRaw runs one expression in the page and returns its value as JSON,
// exactly as Runtime.evaluate reported it.
func (s *Session) evaluateRaw(ctx context.Context, sessionID, expression string) (json.RawMessage, error) {
	raw, err := s.client.Call(ctx, sessionID, cdpMethodRuntimeEvaluate, cdpRuntimeEvaluateParams{
		Expression:    expression,
		ReturnByValue: true,
		AwaitPromise:  true,
	})
	if err != nil {
		return nil, err
	}
	var evaluated cdpRuntimeEvaluateResult
	if err := json.Unmarshal(raw, &evaluated); err != nil {
		return nil, fmt.Errorf("decode Runtime.evaluate: %w", err)
	}
	if evaluated.ExceptionDetails != nil {
		text := evaluated.ExceptionDetails.Text
		if description := remoteObjectText(evaluated.ExceptionDetails.Exception); description != "" {
			text = strings.TrimSpace(text + " " + description)
		}
		return nil, fmt.Errorf("browser: %s", strings.TrimSpace(text))
	}
	value := json.RawMessage(evaluated.Result.Value)
	if len(value) == 0 {
		value = json.RawMessage("null")
	}
	return value, nil
}

// evaluate runs one expression and decodes its value into target.
//
// The unwrapping matters: an expression that answers with JSON.stringify(...)
// reports a JS string whose contents are JSON, and a caller that unmarshals that
// directly gets a string instead of the object it asked for.
func (s *Session) evaluate(ctx context.Context, sessionID, expression string, target any) error {
	value, err := s.evaluateRaw(ctx, sessionID, expression)
	if err != nil {
		return err
	}
	decoded := value
	if text, err := strconv.Unquote(string(value)); err == nil {
		decoded = json.RawMessage(text)
	}
	if len(decoded) == 0 || string(decoded) == "null" {
		return fmt.Errorf("browser: expression returned no value")
	}
	if err := json.Unmarshal(decoded, target); err != nil {
		return fmt.Errorf("decode expression result: %w", err)
	}
	return nil
}

// resolvePoint turns an action's target into a viewport coordinate.
//
// The order is selector, then visible text, then explicit coordinates. That is
// the order an agent reasons in: it addresses what it can name, and only falls
// back to geometry when it has a screenshot with no DOM.
func (s *Session) resolvePoint(ctx context.Context, sessionID string, action api.BrowserAction) ([2]float64, string, error) {
	if action.X != nil && action.Y != nil {
		point := [2]float64{*action.X, *action.Y}
		return point, "", nil
	}
	selector := strings.TrimSpace(action.Selector)
	text := strings.TrimSpace(action.Text)
	if selector == "" && text == "" {
		return [2]float64{}, "", errors.New("browser: action needs a selector, text, or coordinates")
	}
	var point struct {
		Found    bool    `json:"found"`
		Visible  bool    `json:"visible"`
		X        float64 `json:"x"`
		Y        float64 `json:"y"`
		Selector string  `json:"selector"`
	}
	if err := s.evaluate(ctx, sessionID, pointExpression(selector, text), &point); err != nil {
		return [2]float64{}, "", err
	}
	if !point.Found {
		return [2]float64{}, "", fmt.Errorf("browser: no element matches %q", firstNonEmpty(selector, text))
	}
	if !point.Visible {
		return [2]float64{}, "", fmt.Errorf("browser: element %q is not visible", point.Selector)
	}
	return [2]float64{point.X, point.Y}, point.Selector, nil
}

func (s *Session) dispatchMouse(ctx context.Context, sessionID string, params cdpInputMouseEventParams) error {
	_, err := s.client.Call(ctx, sessionID, cdpMethodInputDispatchMouseEvent, params)
	return err
}

func (s *Session) dispatchKey(ctx context.Context, sessionID string, spec keySpec, eventType, text string) error {
	params := cdpInputKeyEventParams{
		Type:                  eventType,
		Key:                   spec.Key,
		Code:                  spec.Code,
		Text:                  text,
		UnmodifiedText:        text,
		WindowsVirtualKeyCode: spec.VirtualKey,
		NativeVirtualKeyCode:  virtualKeyForPlatform(spec.VirtualKey),
	}
	if text == "" {
		params.UnmodifiedText = ""
	}
	_, err := s.client.Call(ctx, sessionID, cdpMethodInputDispatchKeyEvent, params)
	return err
}

// waitDuration resolves how long a navigation or a bare wait blocks. The
// waitUntil field names the load event; "none" means do not wait at all.
func waitDuration(waitUntil string) time.Duration {
	switch strings.ToLower(strings.TrimSpace(waitUntil)) {
	case "none":
		return 0
	case "domcontentloaded", "networkidle":
		return 30 * time.Second
	default:
		return 15 * time.Second
	}
}

// remoteObjectText renders a CDP remote object for an error message.
func remoteObjectText(object cdpRemoteObject) string {
	if len(object.Value) == 0 {
		return object.Description
	}
	var value any
	if err := json.Unmarshal(object.Value, &value); err != nil {
		return strings.Trim(string(object.Value), `"`)
	}
	if text, ok := value.(string); ok {
		return text
	}
	return fmt.Sprint(value)
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return strings.TrimSpace(value)
		}
	}
	return ""
}

// itoa keeps the small numeric conversions in this file readable.
func itoa(value int) string { return strconv.Itoa(value) }
