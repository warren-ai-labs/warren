// Package releaseconfig contains values injected into Warren release
// binaries. A release can replace the public default with -ldflags; source
// builds retain a safe documentation endpoint so Public Access always has an
// actionable Edge URL to show in Settings.
package releaseconfig

// DefaultGnarEdge is the non-secret gnar Edge URL shipped by a release.
//
// Release builds set it with the Go linker, for example:
//
//	-ldflags "-X github.com/abcdlsj/warren/Headless/internal/releaseconfig.DefaultGnarEdge=https://edge.example.com"
//
// It is deliberately a variable (rather than a constant) so the release
// pipeline can replace it without editing user-facing source or settings.
var DefaultGnarEdge = "https://tunnel.example.com"
