package browser

// keySpec describes one key for Input.dispatchKeyEvent.
//
// The virtual key codes are the Windows layout-independent codes CDP expects;
// they are the same on every platform because CDP models the Windows key event.
// The native code is derived from them in dispatchKey.
type keySpec struct {
	Key        string
	Code       string
	Text       string
	VirtualKey int
}

// keySpecs covers the keys an agent presses. Anything outside this table is
// still dispatched, using its name as both key and code, so a rare key does not
// become a hard error.
var keySpecs = map[string]keySpec{
	"enter":      {Key: "Enter", Code: "Enter", VirtualKey: 13},
	"return":     {Key: "Enter", Code: "Enter", VirtualKey: 13},
	"tab":        {Key: "Tab", Code: "Tab", VirtualKey: 9},
	"escape":     {Key: "Escape", Code: "Escape", VirtualKey: 27},
	"esc":        {Key: "Escape", Code: "Escape", VirtualKey: 27},
	"backspace":  {Key: "Backspace", Code: "Backspace", VirtualKey: 8},
	"delete":     {Key: "Delete", Code: "Delete", VirtualKey: 46},
	"space":      {Key: " ", Code: "Space", Text: " ", VirtualKey: 32},
	"arrowup":    {Key: "ArrowUp", Code: "ArrowUp", VirtualKey: 38},
	"arrowdown":  {Key: "ArrowDown", Code: "ArrowDown", VirtualKey: 40},
	"arrowleft":  {Key: "ArrowLeft", Code: "ArrowLeft", VirtualKey: 37},
	"arrowright": {Key: "ArrowRight", Code: "ArrowRight", VirtualKey: 39},
	"home":       {Key: "Home", Code: "Home", VirtualKey: 36},
	"end":        {Key: "End", Code: "End", VirtualKey: 35},
	"pageup":     {Key: "PageUp", Code: "PageUp", VirtualKey: 33},
	"pagedown":   {Key: "PageDown", Code: "PageDown", VirtualKey: 34},
	"up":         {Key: "ArrowUp", Code: "ArrowUp", VirtualKey: 38},
	"down":       {Key: "ArrowDown", Code: "ArrowDown", VirtualKey: 40},
	"left":       {Key: "ArrowLeft", Code: "ArrowLeft", VirtualKey: 37},
	"right":      {Key: "ArrowRight", Code: "ArrowRight", VirtualKey: 39},
}

// virtualKeyForName guesses a Windows virtual key code for a single printable
// character. Only the alphanumeric and symbol ranges are covered; anything else
// falls back to the character's own code point, which is what CDP wants for
// keys it does not model.
func virtualKeyForName(name string) int {
	if name == "" {
		return 0
	}
	runes := []rune(name)
	if len(runes) != 1 {
		return 0
	}
	char := runes[0]
	switch {
	case char >= 'a' && char <= 'z':
		return int(char - 'a' + 65)
	case char >= 'A' && char <= 'Z':
		return int(char - 'A' + 65)
	case char >= '0' && char <= '9':
		return int(char)
	default:
		return int(char)
	}
}

// virtualKeyForPlatform maps a Windows virtual key code to the platform's
// native key code. CDP requires the native code for a key event to reach the
// renderer at all on macOS, where the codes are entirely different.
func virtualKeyForPlatform(windowsVirtualKey int) int {
	if windowsVirtualKey == 0 {
		return 0
	}
	if native, ok := macNativeKeyCodes[windowsVirtualKey]; ok {
		return native
	}
	// Printable characters use their own code point on macOS.
	return windowsVirtualKey
}

// macNativeKeyCodes maps the Windows virtual key codes used above to macOS
// native key codes. Only the keys an agent presses are listed.
var macNativeKeyCodes = map[int]int{
	8:  51,  // Backspace
	9:  48,  // Tab
	13: 36,  // Return
	27: 53,  // Escape
	32: 49,  // Space
	33: 116, // PageUp
	34: 121, // PageDown
	35: 119, // End
	36: 115, // Home
	37: 123, // ArrowLeft
	38: 126, // ArrowUp
	39: 124, // ArrowRight
	40: 125, // ArrowDown
	46: 117, // Delete
}
