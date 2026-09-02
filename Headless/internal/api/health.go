package api

// HealthStatus is the typed readiness payload returned by GET /healthz.
// Clients should treat "ok" as "the daemon is responding" and "ready" as
// "every subsystem is currently in working order". The two flags are kept
// separate so a degraded but-running daemon can be observed without flipping
// menu bar / probe liveness lights.
type HealthStatus struct {
	OK      bool                `json:"ok"`
	Ready   bool                `json:"ready"`
	Version string              `json:"version,omitempty"`
	Build   string              `json:"build,omitempty"`
	// Subsystem fields, in the order a probe should check them.
	Status HealthSubsystems `json:"status"`
}

type HealthSubsystems struct {
	// Store is "ready" when the durable state is loaded and queryable,
	// "unavailable" when the Service or its Store have not finished wiring.
	Store string `json:"store"`
	// Migrations is "cleared" when no Ghostline migration is in flight,
	// "pending" when an in-flight migration has skipped sessions.
	Migrations string `json:"migrations"`
	// GhostlineSkippedSessions is the count of sessions the latest
	// migration left on the legacy socket. Zero means the migration is
	// fully drained or never started.
	GhostlineSkippedSessions int `json:"ghostlineSkippedSessions"`
	// Relay is the supervised outbound connector state. Configured is
	// independent of Connected: a host can be configured but disconnected
	// while the daemon retries.
	Relay RelayHealth `json:"relay"`
}

const (
	HealthReady        = "ready"
	HealthUnavailable  = "unavailable"
	HealthCleared      = "cleared"
	HealthPending      = "pending"
	HealthUnconfigured = "unconfigured"
	HealthDisconnected = "disconnected"
	HealthConnected    = "connected"
	HealthError        = "error"
)

// RelayHealth describes the supervised outbound connector. State is one of
// unconfigured, disconnected, connected, or error. LastError is non-empty
// only when State is "error" or "disconnected" after the last reconnect
// attempt failed.
type RelayHealth struct {
	Configured bool   `json:"configured"`
	Connected  bool   `json:"connected"`
	State      string `json:"state"`
	LastError  string `json:"lastError,omitempty"`
}
