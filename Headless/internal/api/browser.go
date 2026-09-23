package api

// Warren Browser types (RFC 0022). A browser is a Warren Session with
// kind = "browser"; these types describe the runtime projection of one, which
// is what a client needs to render and drive it. The durable identity is the
// Session record itself.

// BrowserSession is the live projection of one managed Chromium instance.
//
// It is overlaid on roster reads and is never persisted as its own record:
// Executable, Phase, DebuggingPort, and the tab list are runtime facts that
// stop being true the moment the process dies.
type BrowserSession struct {
	// ID is the Warren Session ID. A browser is a Session, not a parallel
	// resource with a parallel ID space.
	ID string `json:"id"`
	// WorkspaceID and TerminalGroupID are mutually exclusive owners, exactly as
	// they are for a Session.
	WorkspaceID     string `json:"workspace,omitempty"`
	TerminalGroupID string `json:"terminalGroup,omitempty"`
	Scope           string `json:"scope,omitempty"`
	Title           string `json:"title"`

	// Executable is the resolved Chromium binary. Empty when Phase is
	// unavailable.
	Executable string `json:"executable,omitempty"`
	// UserDataDir is the isolated profile directory. It is per Session and is
	// removed when the Session ends.
	UserDataDir string `json:"userDataDir,omitempty"`
	// DebuggingPort is the loopback CDP port. Zero until the process answers.
	DebuggingPort int `json:"debuggingPort,omitempty"`

	// Headless reports whether the Chromium instance runs without a window.
	// A headless Session can still produce screenshots and snapshots, which is
	// what makes agent-side verification possible on a machine with no display.
	Headless bool `json:"headless,omitempty"`

	// Phase is the runtime lifecycle, deliberately parallel to the Embedded
	// Editor's phase so the two read the same way:
	// idle | starting | ready | unavailable | failed | ended.
	Phase string `json:"phase"`
	// Error is the human-readable reason Phase is unavailable or failed. It
	// carries the executable search list when nothing resolved.
	Error string `json:"error,omitempty"`

	// URL and PageTitle describe the active tab.
	URL       string `json:"url,omitempty"`
	PageTitle string `json:"pageTitle,omitempty"`

	// Viewport is the page size the screencast and screenshots are captured at.
	Viewport BrowserViewport `json:"viewport"`
	// Tabs are the Chromium page targets owned by this Session. A tab is not a
	// Warren Session.
	Tabs []BrowserTab `json:"tabs,omitempty"`

	CreatedAt string `json:"createdAt,omitempty"`
	EndedAt   string `json:"endedAt,omitempty"`
}

// BrowserViewport is a page size in CSS pixels.
type BrowserViewport struct {
	Width  int `json:"width"`
	Height int `json:"height"`
}

// BrowserTab is one Chromium page target.
type BrowserTab struct {
	// ID is the CDP target ID. It is opaque and stable for the target's life.
	ID string `json:"id"`
	// URL is the target's current URL. Chrome reports "about:blank" for a
	// freshly created target and a chrome:// URL for the initial tab.
	URL string `json:"url"`
	// Title is the target's document title, empty before the first commit.
	Title string `json:"title,omitempty"`
	// Active reports whether this is the tab the Session's actions apply to.
	Active bool `json:"active,omitempty"`
}

// BrowserAction is one normalized browser-use-style action.
//
// The action set is closed. An unknown Action is a protocol error rather than a
// passthrough, because a passthrough would make Warren's protocol a proxy for
// CDP. `evaluate` is the deliberate escape hatch for the long tail.
type BrowserAction struct {
	// Action names the operation. One of the BrowserAction* constants.
	Action string `json:"action"`

	// URL is used by navigate.
	URL string `json:"url,omitempty"`
	// WaitUntil is used by navigate: "load" (default), "domcontentloaded",
	// "networkidle", or "none".
	WaitUntil string `json:"waitUntil,omitempty"`

	// Selector is a CSS selector. It is the primary way to address an element.
	Selector string `json:"selector,omitempty"`
	// Text addresses an element by its visible text when Selector is empty.
	Text string `json:"text,omitempty"`
	// X and Y are viewport coordinates, used when neither Selector nor Text is
	// given. They are also what click and hover fall back to.
	X *float64 `json:"x,omitempty"`
	Y *float64 `json:"y,omitempty"`

	// Value carries the payload for type, press, and select. For select it is a
	// JSON array of option values.
	Value string `json:"value,omitempty"`
	// Values carries select's option values, kept separate from Value so the
	// wire shape does not have to encode a list inside a string.
	Values []string `json:"values,omitempty"`

	// ClearFirst empties the target before typing.
	ClearFirst bool `json:"clearFirst,omitempty"`
	// DelayMs is the per-keystroke delay for type.
	DelayMs int `json:"delayMs,omitempty"`
	// Hard forces a cache-bypassing reload.
	Hard bool `json:"hard,omitempty"`
	// FullPage captures beyond the viewport for screenshot.
	FullPage bool `json:"fullPage,omitempty"`
	// Format is the image format screenshot writes: "png" (default), "jpeg",
	// "jpg", or "webp". The live stream is always JPEG because it is bandwidth;
	// the saved file defaults to PNG because it is evidence.
	Format string `json:"format,omitempty"`
	// Quality is the lossy quality 1-100 for a screenshot that is not PNG.
	// Ignored for PNG. Default 80.
	Quality int `json:"quality,omitempty"`
	// Path writes the screenshot to a file instead of returning it inline. This
	// is the verification path: an agent writes the file and reads it, rather
	// than spending context on an image.
	Path string `json:"path,omitempty"`
	// InteractiveOnly restricts snapshot to interactive nodes.
	InteractiveOnly bool `json:"interactiveOnly,omitempty"`
	// MaxNodes caps snapshot's node count. Zero means the runtime default.
	MaxNodes int `json:"maxNodes,omitempty"`

	// TimeoutMs bounds wait. Zero means the runtime default.
	TimeoutMs int `json:"timeoutMs,omitempty"`
	// State is what wait waits for: "visible" (default), "hidden", "attached",
	// or "detached".
	State string `json:"state,omitempty"`
	// Level filters console entries: "log", "warn", "error", or "" for all.
	Level string `json:"level,omitempty"`
	// Limit caps console entries. Zero means the runtime default.
	Limit int `json:"limit,omitempty"`

	// DX and DY are scroll deltas in CSS pixels.
	DX int `json:"dx,omitempty"`
	DY int `json:"dy,omitempty"`

	// TabID names a tab for tabs.close and tabs.select.
	TabID string `json:"tabId,omitempty"`
	// Width and Height set the viewport.
	Width  int `json:"width,omitempty"`
	Height int `json:"height,omitempty"`
	// DeviceScaleFactor is the display density a viewer renders at, sent with a
	// viewport action. It is the viewer's `window.devicePixelRatio`, and it
	// changes how many pixels a still carries, never the layout. Zero means
	// "keep the scale this browser already has".
	DeviceScaleFactor float64 `json:"deviceScaleFactor,omitempty"`

	// Expression is the JavaScript evaluated by the evaluate action.
	Expression string `json:"expression,omitempty"`
}

// The closed action vocabulary. Anything outside this set is rejected.
const (
	BrowserActionNavigate  = "navigate"
	BrowserActionBack      = "back"
	BrowserActionForward   = "forward"
	BrowserActionReload    = "reload"
	BrowserActionClick     = "click"
	BrowserActionType      = "type"
	BrowserActionPress     = "press"
	BrowserActionHover     = "hover"
	BrowserActionScroll    = "scroll"
	BrowserActionSelect    = "select"
	BrowserActionWait      = "wait"
	BrowserActionScreenshot = "screenshot"
	BrowserActionSnapshot  = "snapshot"
	BrowserActionEvaluate  = "evaluate"
	BrowserActionTabsList  = "tabs.list"
	BrowserActionTabsNew   = "tabs.new"
	BrowserActionTabsClose = "tabs.close"
	BrowserActionTabsSelect = "tabs.select"
	BrowserActionViewport  = "viewport"
	BrowserActionCookies   = "cookies"
	BrowserActionConsole   = "console"
)

// BrowserActionResult is the outcome of one action.
//
// Result is the action-specific payload; every action also reports the page URL
// and title it left behind, because an agent's next decision almost always
// depends on where it ended up.
type BrowserActionResult struct {
	// Action echoes the requested action.
	Action string `json:"action"`
	// URL and Title are the active tab's state after the action.
	URL   string `json:"url,omitempty"`
	Title string `json:"title,omitempty"`
	// Result is the action-specific payload. Its shape is documented per action
	// in RFC 0022 §6.1.
	Result map[string]any `json:"result,omitempty"`
}

// BrowserDomNode is one flattened node from a snapshot.
//
// Flattened rather than nested because an agent consuming a tree has to
// re-flatten it to find anything, and because the node count is what a caller
// needs in order to bound its own context.
type BrowserDomNode struct {
	Selector    string  `json:"selector,omitempty"`
	Tag         string  `json:"tag"`
	Text        string  `json:"text,omitempty"`
	Role        string  `json:"role,omitempty"`
	Interactive bool    `json:"interactive,omitempty"`
	Enabled     bool    `json:"enabled,omitempty"`
	Visible     bool    `json:"visible,omitempty"`
	Checked     *bool   `json:"checked,omitempty"`
	Rect        *BrowserRect `json:"rect,omitempty"`
}

// BrowserRect is a node's box in CSS pixels relative to the viewport.
type BrowserRect struct {
	X      float64 `json:"x"`
	Y      float64 `json:"y"`
	Width  float64 `json:"width"`
	Height float64 `json:"height"`
}

// BrowserConsoleEntry is one captured console message.
type BrowserConsoleEntry struct {
	Level string `json:"level"`
	Text  string `json:"text"`
	URL   string `json:"url,omitempty"`
	Line  int    `json:"line,omitempty"`
	// Timestamp is Unix milliseconds.
	Timestamp int64 `json:"timestamp"`
}

// BrowserCookie is one cookie as Warren exposes it. The HttpOnly and Secure
// flags are reported so an agent can reason about a session without ever being
// handed a value it does not need.
type BrowserCookie struct {
	Name     string `json:"name"`
	Value    string `json:"value"`
	Domain   string `json:"domain,omitempty"`
	Path     string `json:"path,omitempty"`
	Expires  float64 `json:"expires,omitempty"`
	HTTPOnly bool   `json:"httpOnly,omitempty"`
	Secure   bool   `json:"secure,omitempty"`
	SameSite string `json:"sameSite,omitempty"`
}
