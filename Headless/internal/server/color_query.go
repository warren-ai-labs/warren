package server

import "github.com/abcdlsj/ghostline"

const (
	warrenTerminalForeground = "#ededed"
	warrenTerminalBackground = "#0b0b0b"
)

// WarrenColorQuery supplies Warren's dark terminal colors to ghostline.
func WarrenColorQuery(kind ghostline.ColorQueryKind) (string, bool) {
	switch kind {
	case ghostline.ColorQueryForeground:
		return warrenTerminalForeground, true
	case ghostline.ColorQueryBackground:
		return warrenTerminalBackground, true
	default:
		return "", false
	}
}
