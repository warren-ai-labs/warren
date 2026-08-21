// Package releaseconfig contains values injected into Warren release
// binaries. Development builds intentionally leave these values empty so
// local installations keep using gnar's own edge discovery behavior.
package releaseconfig

// DefaultGnarEdge is the non-secret gnar Edge URL shipped by a release.
//
// Release builds set it with the Go linker, for example:
//
//	-ldflags "-X github.com/abcdlsj/warren/Headless/internal/releaseconfig.DefaultGnarEdge=https://edge.example.com"
//
// It is deliberately a variable (rather than a constant) so the release
// pipeline can replace it without editing user-facing source or settings.
var DefaultGnarEdge = ""
