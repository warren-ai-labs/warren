// Package browser owns the Warren Browser runtime (RFC 0022): a managed
// Chromium process driven over the Chrome DevTools Protocol, exposed to clients
// through a normalized action set.
//
// The package deliberately does not re-export CDP. It speaks CDP internally and
// publishes an action vocabulary that is small enough to be a contract.
package browser

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

// CDP method names used by this package. Only stable, pre-1.0 domains are
// referenced, so a Chrome upgrade is unlikely to break them.
const (
	cdpMethodBrowserGetVersion      = "Browser.getVersion"
	cdpMethodTargetGetTargets       = "Target.getTargets"
	cdpMethodTargetAttachToTarget   = "Target.attachToTarget"
	cdpMethodTargetCreateTarget     = "Target.createTarget"
	cdpMethodTargetCloseTarget      = "Target.closeTarget"
	cdpMethodTargetActivateTarget   = "Target.activateTarget"
	cdpMethodTargetDetachFromTarget = "Target.detachFromTarget"

	cdpMethodPageEnable               = "Page.enable"
	cdpMethodPageNavigate             = "Page.navigate"
	cdpMethodPageReload               = "Page.reload"
	cdpMethodPageCaptureScreenshot    = "Page.captureScreenshot"
	cdpMethodPageStartScreencast      = "Page.startScreencast"
	cdpMethodPageStopScreencast       = "Page.stopScreencast"
	cdpMethodPageScreencastFrameAck   = "Page.screencastFrameAck"
	cdpMethodPageNavigateHistory      = "Page.navigateToHistoryEntry"
	cdpMethodPageGetNavigationHistory = "Page.getNavigationHistory"

	cdpMethodRuntimeEvaluate       = "Runtime.evaluate"
	cdpMethodRuntimeEnable         = "Runtime.enable"
	cdpMethodRuntimeCallFunctionOn = "Runtime.callFunctionOn"

	cdpMethodInputDispatchMouseEvent = "Input.dispatchMouseEvent"
	cdpMethodInputDispatchKeyEvent   = "Input.dispatchKeyEvent"

	cdpMethodDOMGetDocument   = "DOM.getDocument"
	cdpMethodDOMQuerySelector = "DOM.querySelector"
	cdpMethodDOMGetBoxModel   = "DOM.getBoxModel"
	cdpMethodDOMResolveNode   = "DOM.resolveNode"
	cdpMethodDOMEnable        = "DOM.enable"

	cdpMethodNetworkEnable              = "Network.enable"
	cdpMethodNetworkGetCookies          = "Network.getCookies"
	cdpMethodNetworkSetCookie           = "Network.setCookie"
	cdpMethodNetworkClearBrowserCookies = "Network.clearBrowserCookies"

	cdpMethodEmulationSetDeviceMetricsOverride = "Emulation.setDeviceMetricsOverride"
)

// CDP event names this package subscribes to.
const (
	cdpEventScreencastFrame          = "Page.screencastFrame"
	cdpEventFrameNavigated           = "Page.frameNavigated"
	cdpEventFrameStoppedLoading      = "Page.frameStoppedLoading"
	cdpEventJavascriptDialogOpening  = "Page.javascriptDialogOpening"
	cdpEventRuntimeConsoleAPICalled  = "Runtime.consoleAPICalled"
	cdpEventRuntimeExceptionThrown   = "Runtime.exceptionThrown"
	cdpEventTargetAttachedToTarget   = "Target.attachedToTarget"
	cdpEventTargetDetachedFromTarget = "Target.detachedFromTarget"
	cdpEventInspectorTargetCrashed   = "Inspector.targetCrashed"
)

// Default timeout for one CDP round trip. Deliberately short: an action that
// cannot be answered in 30s has failed, and holding a caller for longer turns a
// broken page into a hung Host.
const defaultCDPTimeout = 30 * time.Second

// errCDPTimeout is returned when a method has no response within the timeout.
var errCDPTimeout = errors.New("cdp: method timed out")

// cdpError is an error Chrome itself reported for a method.
type cdpError struct {
	Code    int             `json:"code"`
	Message string          `json:"message"`
	Data    json.RawMessage `json:"data,omitempty"`
}

func (e *cdpError) Error() string {
	if e == nil {
		return "cdp: unknown error"
	}
	return fmt.Sprintf("cdp: %s (code %d)", e.Message, e.Code)
}

// cdpMessage is one WebSocket frame. Chrome sends and receives the same shape:
// id for methods, method/params for events, and result or error for replies.
type cdpMessage struct {
	ID     int             `json:"id,omitempty"`
	Method string          `json:"method,omitempty"`
	Params json.RawMessage `json:"params,omitempty"`
	Result json.RawMessage `json:"result,omitempty"`
	Error  *cdpError       `json:"error,omitempty"`
	// SessionID scopes the message to one attached target. Chrome omits it for
	// browser-level commands.
	SessionID string `json:"sessionId,omitempty"`
}

// cdpTarget describes one Chromium target from Target.getTargets.
type cdpTarget struct {
	TargetID string `json:"targetId"`
	Type     string `json:"type"`
	Title    string `json:"title"`
	URL      string `json:"url"`
	Attached bool   `json:"attached"`
}

// cdpTargets is the result of Target.getTargets.
type cdpTargets struct {
	TargetInfos []cdpTarget `json:"targetInfos"`
}

// cdpClient is a single WebSocket connection to one Chromium debugging
// endpoint. It is safe for concurrent use: calls are correlated by id and
// events are dispatched to registered handlers.
type cdpClient struct {
	conn *websocket.Conn

	writeMu sync.Mutex

	nextID    int
	pending   map[int]chan cdpMessage
	pendingMu sync.Mutex

	handlerMu sync.Mutex
	handlers  map[string][]func(sessionID string, params json.RawMessage)

	closed    chan struct{}
	closeOnce sync.Once
	// onClose runs once when the read loop exits, so the owning session can
	// mark itself dead rather than leaving a half-connected runtime behind.
	onClose func()
}

// dialCDP connects to a Chromium debugging endpoint and starts the read loop.
//
// The Origin header is deliberately not set: Chrome accepts a debugger with no
// Origin, and the --remote-allow-origins escape hatch that a browser-based
// debugger needs is not enabled by the launcher.
func dialCDP(ctx context.Context, wsURL string) (*cdpClient, error) {
	dialer := *websocket.DefaultDialer
	dialer.HandshakeTimeout = 10 * time.Second
	conn, _, err := dialer.DialContext(ctx, wsURL, nil)
	if err != nil {
		return nil, fmt.Errorf("dial %s: %w", wsURL, err)
	}
	client := &cdpClient{
		conn:     conn,
		pending:  make(map[int]chan cdpMessage),
		handlers: make(map[string][]func(string, json.RawMessage)),
		closed:   make(chan struct{}),
	}
	go client.readLoop()
	return client, nil
}

// Call sends one method and waits for its result. An empty sessionID targets
// the browser-level endpoint.
func (c *cdpClient) Call(ctx context.Context, sessionID, method string, params any) (json.RawMessage, error) {
	id, reply := c.register()
	defer c.unregister(id)

	payload, err := json.Marshal(params)
	if err != nil {
		return nil, fmt.Errorf("cdp: encode %s params: %w", method, err)
	}
	if len(payload) == 0 || string(payload) == "null" {
		payload = json.RawMessage("{}")
	}

	message := cdpMessage{
		ID:        id,
		Method:    method,
		Params:    payload,
		SessionID: sessionID,
	}
	if err := c.writeJSON(message); err != nil {
		return nil, err
	}

	timeout := defaultCDPTimeout
	if deadline, ok := ctx.Deadline(); ok {
		if remaining := time.Until(deadline); remaining < timeout {
			timeout = remaining
		}
	}
	timer := time.NewTimer(timeout)
	defer timer.Stop()

	select {
	case response := <-reply:
		if response.Error != nil {
			return nil, response.Error
		}
		return response.Result, nil
	case <-timer.C:
		return nil, fmt.Errorf("%w: %s", errCDPTimeout, method)
	case <-c.closed:
		return nil, fmt.Errorf("cdp: connection closed during %s", method)
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

// On registers a handler for one CDP event. Handlers run on the read loop
// goroutine, so they must not block.
//
// The session ID is passed because a flattened target delivers its events on
// the same socket as browser-level ones, and a handler that cannot tell which
// target an event came from would apply one tab's frames to another.
func (c *cdpClient) On(method string, handler func(sessionID string, params json.RawMessage)) {
	c.handlerMu.Lock()
	defer c.handlerMu.Unlock()
	c.handlers[method] = append(c.handlers[method], handler)
}

// AckScreencastFrame acknowledges one Page.screencastFrame so Chrome sends the
// next one.
//
// The message must carry an id. Chrome discards an ack sent as a notification
// and keeps withholding frames, which presents as a screencast that delivers a
// few images and then stops forever. The reply Chrome sends back is empty and is
// deliberately not awaited: this runs on the read loop, and waiting there for a
// reply that only the read loop can deliver would deadlock the connection.
// Allocating an id without registering it lets deliver drop the reply, which is
// what should happen to it.
func (c *cdpClient) AckScreencastFrame(sessionID string, frameSessionID int) error {
	payload, err := json.Marshal(cdpPageScreencastFrameAckParams{SessionID: frameSessionID})
	if err != nil {
		return fmt.Errorf("cdp: encode %s params: %w", cdpMethodPageScreencastFrameAck, err)
	}
	return c.writeJSON(cdpMessage{
		ID:        c.nextMessageID(),
		Method:    cdpMethodPageScreencastFrameAck,
		Params:    payload,
		SessionID: sessionID,
	})
}

// Close terminates the connection and the read loop.
func (c *cdpClient) Close() error {
	c.closeOnce.Do(func() {
		close(c.closed)
	})
	c.writeMu.Lock()
	err := c.conn.Close()
	c.writeMu.Unlock()
	if c.onClose != nil {
		c.onClose()
	}
	return err
}

func (c *cdpClient) register() (int, chan cdpMessage) {
	id := c.nextMessageID()
	reply := make(chan cdpMessage, 1)
	c.pendingMu.Lock()
	c.pending[id] = reply
	c.pendingMu.Unlock()
	return id, reply
}

// nextMessageID allocates the next message id. It is shared with AckScreencastFrame
// so an unawaited ack can never collide with a call waiting for its reply.
func (c *cdpClient) nextMessageID() int {
	c.pendingMu.Lock()
	defer c.pendingMu.Unlock()
	c.nextID++
	return c.nextID
}

func (c *cdpClient) unregister(id int) {
	c.pendingMu.Lock()
	defer c.pendingMu.Unlock()
	delete(c.pending, id)
}

func (c *cdpClient) writeJSON(message cdpMessage) error {
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	if err := c.conn.SetWriteDeadline(time.Now().Add(defaultCDPTimeout)); err != nil {
		return fmt.Errorf("cdp: set write deadline: %w", err)
	}
	if err := c.conn.WriteJSON(message); err != nil {
		return fmt.Errorf("cdp: write %s: %w", message.Method, err)
	}
	return nil
}

func (c *cdpClient) readLoop() {
	defer c.Close()
	for {
		var message cdpMessage
		if err := c.conn.ReadJSON(&message); err != nil {
			return
		}
		if message.ID != 0 {
			c.deliver(message)
			continue
		}
		if message.Method != "" {
			c.dispatch(message)
		}
	}
}

func (c *cdpClient) deliver(message cdpMessage) {
	c.pendingMu.Lock()
	reply, ok := c.pending[message.ID]
	c.pendingMu.Unlock()
	if !ok {
		return
	}
	select {
	case reply <- message:
	default:
	}
}

func (c *cdpClient) dispatch(message cdpMessage) {
	c.handlerMu.Lock()
	registered := c.handlers[message.Method]
	handlers := make([]func(string, json.RawMessage), len(registered))
	copy(handlers, registered)
	c.handlerMu.Unlock()
	for _, handler := range handlers {
		handler(message.SessionID, message.Params)
	}
}

// cdpPageNavigateParams is Page.navigate.
type cdpPageNavigateParams struct {
	URL            string `json:"url"`
	FrameID        string `json:"frameId,omitempty"`
	Referrer       string `json:"referrer,omitempty"`
	TransitionType string `json:"transitionType,omitempty"`
}

// cdpPageReloadParams is Page.reload.
type cdpPageReloadParams struct {
	IgnoreCache            bool   `json:"ignoreCache,omitempty"`
	ScriptToEvaluateOnLoad string `json:"scriptToEvaluateOnLoad,omitempty"`
}

// cdpPageCaptureScreenshotParams is Page.captureScreenshot.
type cdpPageCaptureScreenshotParams struct {
	Format  string   `json:"format,omitempty"`
	Quality int      `json:"quality,omitempty"`
	Clip    *cdpClip `json:"clip,omitempty"`
	// CaptureBeyondViewport is what fullPage reduces to: Chrome scrolls the
	// page itself and returns one image.
	CaptureBeyondViewport bool `json:"captureBeyondViewport,omitempty"`
	// FromSurface is required when the renderer is throttled or the page has not
	// painted; Chrome returns an error rather than an empty image without it.
	FromSurface bool `json:"fromSurface,omitempty"`
}

// cdpClip is a screenshot clip rectangle in CSS pixels.
type cdpClip struct {
	X      float64 `json:"x"`
	Y      float64 `json:"y"`
	Width  float64 `json:"width"`
	Height float64 `json:"height"`
	Scale  float64 `json:"scale"`
}

// cdpScreenshotResult is the result of Page.captureScreenshot.
type cdpScreenshotResult struct {
	Data string `json:"data"`
}

// cdpPageStartScreencastParams is Page.startScreencast.
type cdpPageStartScreencastParams struct {
	Format        string `json:"format,omitempty"`
	Quality       int    `json:"quality,omitempty"`
	MaxWidth      int    `json:"maxWidth,omitempty"`
	MaxHeight     int    `json:"maxHeight,omitempty"`
	EveryNthFrame int    `json:"everyNthFrame,omitempty"`
}

// cdpScreencastFrame is the payload of Page.screencastFrame.
type cdpScreencastFrame struct {
	Data      string                `json:"data"`
	Metadata  cdpScreencastMetadata `json:"metadata"`
	SessionID int                   `json:"sessionId"`
}

// cdpPageScreencastFrameAckParams is Page.screencastFrameAck.
//
// The sessionId here is not the CDP target session: it is the frame number from
// the Page.screencastFrame event being acknowledged. Chrome withholds the next
// frame until the current one is acked, so this value must be echoed exactly —
// an ack carrying the wrong number leaves the stream stalled.
type cdpPageScreencastFrameAckParams struct {
	SessionID int `json:"sessionId"`
}

// cdpScreencastMetadata describes one screencast frame. OffsetTop and
// PageScaleFactor matter for input mapping: a scrolled page reports a non-zero
// offset, and forwarding a click without it lands on the wrong element.
type cdpScreencastMetadata struct {
	OffsetTop       float64 `json:"offsetTop"`
	PageScaleFactor float64 `json:"pageScaleFactor"`
	DeviceWidth     float64 `json:"deviceWidth"`
	DeviceHeight    float64 `json:"deviceHeight"`
	ScrollOffsetX   float64 `json:"scrollOffsetX"`
	ScrollOffsetY   float64 `json:"scrollOffsetY"`
	Timestamp       float64 `json:"timestamp"`
}

// cdpRuntimeEvaluateParams is Runtime.evaluate.
type cdpRuntimeEvaluateParams struct {
	Expression    string `json:"expression"`
	ReturnByValue bool   `json:"returnByValue"`
	AwaitPromise  bool   `json:"awaitPromise"`
	UserGesture   bool   `json:"userGesture,omitempty"`
}

// cdpRuntimeEvaluateResult is the result of Runtime.evaluate.
type cdpRuntimeEvaluateResult struct {
	Result           cdpRemoteObject      `json:"result"`
	ExceptionDetails *cdpExceptionDetails `json:"exceptionDetails,omitempty"`
}

// cdpRemoteObject is a Runtime.evaluate value. Only the type and value are
// consumed; an object handle is deliberately dropped so nothing keeps a
// renderer-side reference alive.
type cdpRemoteObject struct {
	Type        string          `json:"type"`
	Subtype     string          `json:"subtype,omitempty"`
	Description string          `json:"description,omitempty"`
	Value       json.RawMessage `json:"value,omitempty"`
}

// cdpExceptionDetails is a Runtime.evaluate failure.
type cdpExceptionDetails struct {
	Text string `json:"text"`
	// Exception carries the thrown value's description.
	Exception cdpRemoteObject `json:"exception"`
}

// cdpInputMouseEventParams is Input.dispatchMouseEvent.
//
// DeltaX and DeltaY are deliberately not `omitempty`: a mouseWheel event with a
// zero delta on one axis is legal, but an omitted axis is not, and Chrome rejects
// the whole event with "'deltaX' and 'deltaY' are expected". A straight vertical
// scroll is exactly that case, so omitting them made every mouse wheel a no-op.
type cdpInputMouseEventParams struct {
	Type       string  `json:"type"`
	X          float64 `json:"x"`
	Y          float64 `json:"y"`
	Button     string  `json:"button,omitempty"`
	Buttons    int     `json:"buttons,omitempty"`
	ClickCount int     `json:"clickCount,omitempty"`
	DeltaX     float64 `json:"deltaX"`
	DeltaY     float64 `json:"deltaY"`
	Modifiers  int     `json:"modifiers,omitempty"`
}

// cdpInputKeyEventParams is Input.dispatchKeyEvent.
type cdpInputKeyEventParams struct {
	Type                  string `json:"type"`
	Key                   string `json:"key,omitempty"`
	Code                  string `json:"code,omitempty"`
	Text                  string `json:"text,omitempty"`
	UnmodifiedText        string `json:"unmodifiedText,omitempty"`
	NativeVirtualKeyCode  int    `json:"nativeVirtualKeyCode,omitempty"`
	WindowsVirtualKeyCode int    `json:"windowsVirtualKeyCode,omitempty"`
	Modifiers             int    `json:"modifiers,omitempty"`
}

// cdpTargetAttachParams is Target.attachToTarget. Flattening is required: a
// non-flattened session cannot receive Page and Runtime events.
type cdpTargetAttachParams struct {
	TargetID string `json:"targetId"`
	Flatten  bool   `json:"flatten"`
}

// cdpTargetAttachResult is the result of Target.attachToTarget.
type cdpTargetAttachResult struct {
	SessionID string `json:"sessionId"`
}

// cdpTargetDetached is Target.detachedFromTarget.
//
// The event is browser-scoped, so the envelope carries no sessionId and the
// detached session is named in the params instead. Reading it from the envelope
// would compare an empty string against the page session and never match.
type cdpTargetDetached struct {
	SessionID string `json:"sessionId"`
	TargetID  string `json:"targetId"`
}

// cdpTargetCreateParams is Target.createTarget.
type cdpTargetCreateParams struct {
	URL string `json:"url"`
}

// cdpTargetCreateResult is the result of Target.createTarget.
type cdpTargetCreateResult struct {
	TargetID string `json:"targetId"`
}

// cdpTargetCloseParams is Target.closeTarget.
type cdpTargetCloseParams struct {
	TargetID string `json:"targetId"`
}

// cdpTargetActivateParams is Target.activateTarget.
type cdpTargetActivateParams struct {
	TargetID string `json:"targetId"`
}

// cdpEmulationSetDeviceMetricsParams is Emulation.setDeviceMetricsOverride.
type cdpEmulationSetDeviceMetricsParams struct {
	Width             int     `json:"width"`
	Height            int     `json:"height"`
	DeviceScaleFactor float64 `json:"deviceScaleFactor"`
	Mobile            bool    `json:"mobile"`
}

// cdpDOMQuerySelectorParams is DOM.querySelector.
type cdpDOMQuerySelectorParams struct {
	NodeID   int    `json:"nodeId"`
	Selector string `json:"selector"`
}

// cdpDOMGetDocumentParams is DOM.getDocument.
type cdpDOMGetDocumentParams struct {
	Depth  int  `json:"depth,omitempty"`
	Pierce bool `json:"pierce,omitempty"`
}

// cdpDOMNode is the subset of a DOM node this package reads. NodeID is used to
// address the node for a box model; everything else is ignored because the DOM
// snapshot is computed in the page, not from the CDP DOM tree.
type cdpDOMNode struct {
	NodeID   int    `json:"nodeId"`
	NodeName string `json:"nodeName"`
	NodeType int    `json:"nodeType"`
}

// cdpDOMDocumentResult is the result of DOM.getDocument.
type cdpDOMDocumentResult struct {
	Root cdpDOMNode `json:"root"`
}

// cdpDOMResolveNodeParams is DOM.resolveNode.
type cdpDOMResolveNodeParams struct {
	NodeID int `json:"nodeId"`
}

// cdpRemoteObjectRef is the result of DOM.resolveNode.
type cdpRemoteObjectRef struct {
	Object cdpRemoteObjectWithID `json:"object"`
}

// cdpRemoteObjectWithID is a remote object plus the objectId needed to call a
// function on it.
type cdpRemoteObjectWithID struct {
	Type     string `json:"type"`
	ObjectID string `json:"objectId,omitempty"`
}

// cdpCallFunctionOnParams is Runtime.callFunctionOn.
type cdpCallFunctionOnParams struct {
	ObjectID            string            `json:"objectId"`
	FunctionDeclaration string            `json:"functionDeclaration"`
	Arguments           []cdpCallArgument `json:"arguments,omitempty"`
	ReturnByValue       bool              `json:"returnByValue"`
	UserGesture         bool              `json:"userGesture,omitempty"`
}

// cdpCallArgument is one Runtime.callFunctionOn argument.
type cdpCallArgument struct {
	Value json.RawMessage `json:"value,omitempty"`
}

// cdpNetworkGetCookiesParams is Network.getCookies.
type cdpNetworkGetCookiesParams struct {
	URLs []string `json:"urls,omitempty"`
}

// cdpNetworkCookiesResult is the result of Network.getCookies.
type cdpNetworkCookiesResult struct {
	Cookies []cdpCookie `json:"cookies"`
}

// cdpCookie is one cookie as CDP reports it.
type cdpCookie struct {
	Name     string  `json:"name"`
	Value    string  `json:"value"`
	Domain   string  `json:"domain"`
	Path     string  `json:"path"`
	Expires  float64 `json:"expires"`
	HTTPOnly bool    `json:"httpOnly"`
	Secure   bool    `json:"secure"`
	SameSite string  `json:"sameSite"`
}

// cdpConsoleAPICalled is the payload of Runtime.consoleAPICalled.
type cdpConsoleAPICalled struct {
	Type      string            `json:"type"`
	Timestamp float64           `json:"timestamp"`
	Args      []cdpRemoteObject `json:"args"`
}

// cdpExceptionThrown is the payload of Runtime.exceptionThrown.
type cdpExceptionThrown struct {
	Timestamp        float64             `json:"timestamp"`
	ExceptionDetails cdpExceptionDetails `json:"exceptionDetails"`
}

// cdpFrameNavigated is the payload of Page.frameNavigated.
type cdpFrameNavigated struct {
	Frame cdpFrame `json:"frame"`
}

// cdpFrame is a page frame.
type cdpFrame struct {
	ID   string `json:"id"`
	URL  string `json:"url"`
	Name string `json:"name"`
}

// cdpNavigationHistoryResult is the result of Page.getNavigationHistory.
type cdpNavigationHistoryResult struct {
	CurrentIndex int               `json:"currentIndex"`
	Entries      []cdpHistoryEntry `json:"entries"`
}

// cdpHistoryEntry is one back/forward history entry.
type cdpHistoryEntry struct {
	ID  int    `json:"id"`
	URL string `json:"url"`
}
