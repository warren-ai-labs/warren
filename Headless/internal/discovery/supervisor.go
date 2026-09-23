package discovery

import (
	"context"
	"io"
	"log/slog"
	"net"
	"sync"
	"time"
)

// DefaultRefreshInterval is how often the Supervisor re-checks which addresses
// the Host can be reached on. The check is a local interface list, so the
// cadence trades a negligible amount of work for a short window in which a
// client may still hold the address the Host just lost.
const DefaultRefreshInterval = 5 * time.Second

// SupervisorConfig describes the advertisement and how it is published.
type SupervisorConfig struct {
	// Advertisement carries the Host metadata that does not change while the
	// daemon runs. Any Candidates value is ignored: candidates are derived on
	// every refresh.
	Advertisement Config
	// ListenerAddress is the daemon's HTTP listener. Addresses the listener
	// cannot serve are never advertised.
	ListenerAddress string
	// Addresses overrides the candidate source. The default reports the
	// machine's non-loopback addresses filtered for the listener.
	Addresses func() ([]net.IP, error)
	// Publish overrides the advertiser. The default is Start.
	Publish func(Config) (func() error, error)
	// Interval overrides the refresh cadence. The default is
	// DefaultRefreshInterval.
	Interval time.Duration
	// Logger receives lifecycle and failure messages. The default discards
	// them.
	Logger *slog.Logger
}

// Supervisor keeps the Host's DNS-SD advertisement aligned with the addresses
// reachable right now. The multicast responder captures its records when it
// starts, so a Host that changes network must republish: an advertisement that
// still lists the previous address keeps clients dialing a machine that is no
// longer there until the daemon restarts.
type Supervisor struct {
	advertisement Config
	addresses     func() ([]net.IP, error)
	publish       func(Config) (func() error, error)
	interval      time.Duration
	logger        *slog.Logger

	mu       sync.Mutex
	shutdown func() error
	current  []net.IP
	stopped  bool
}

// NewSupervisor builds a Supervisor. It publishes nothing until Refresh runs.
func NewSupervisor(config SupervisorConfig) *Supervisor {
	logger := config.Logger
	if logger == nil {
		logger = slog.New(slog.NewTextHandler(io.Discard, nil))
	}
	addresses := config.Addresses
	if addresses == nil {
		listener := config.ListenerAddress
		addresses = func() ([]net.IP, error) {
			candidates, err := LocalAddresses()
			if err != nil {
				return nil, err
			}
			return FilterForListener(candidates, listener), nil
		}
	}
	publish := config.Publish
	if publish == nil {
		publish = Start
	}
	interval := config.Interval
	if interval <= 0 {
		interval = DefaultRefreshInterval
	}
	advertisement := config.Advertisement
	advertisement.Candidates = nil
	return &Supervisor{
		advertisement: advertisement,
		addresses:     addresses,
		publish:       publish,
		interval:      interval,
		logger:        logger,
	}
}

// Refresh publishes the advertisement when the candidate set changed, and
// returns whether it did. An unchanged set is left alone: restarting the
// responder would drop the records clients are already using.
func (supervisor *Supervisor) Refresh() bool {
	candidates, err := supervisor.addresses()
	if err != nil {
		supervisor.logger.Warn("Warren LAN discovery disabled", "error", err)
		candidates = nil
	}
	candidates = normalizeIPs(candidates)

	supervisor.mu.Lock()
	defer supervisor.mu.Unlock()
	if supervisor.stopped {
		return false
	}
	if len(candidates) == 0 {
		supervisor.stopLocked("listener has no non-loopback candidates")
		return false
	}
	if supervisor.shutdown != nil && equalAddresses(supervisor.current, candidates) {
		return false
	}

	advertisement := supervisor.advertisement
	advertisement.Candidates = candidates
	// Replace the previous responder before publishing new records so two
	// responders never answer for the same service with different addresses.
	wasPublishing := supervisor.shutdown != nil
	supervisor.stopLocked("")
	shutdown, publishErr := supervisor.publish(advertisement)
	if publishErr != nil {
		supervisor.logger.Warn("Warren LAN discovery disabled", "error", publishErr)
		return false
	}
	supervisor.shutdown = shutdown
	supervisor.current = candidates
	if wasPublishing {
		supervisor.logger.Info(
			"warren LAN discovery candidates updated",
			"service", ServiceType,
			"port", advertisement.Port,
			"candidates", len(candidates),
		)
		return true
	}
	supervisor.logger.Info(
		"warren LAN discovery ready",
		"service", ServiceType,
		"port", advertisement.Port,
		"candidates", len(candidates),
	)
	return true
}

// Run refreshes on the configured interval until the context is cancelled.
func (supervisor *Supervisor) Run(ctx context.Context) {
	ticker := time.NewTicker(supervisor.interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			supervisor.Refresh()
		}
	}
}

// Stop stops advertising. It is safe to call more than once and after Run
// returned.
func (supervisor *Supervisor) Stop() {
	supervisor.mu.Lock()
	supervisor.stopped = true
	shutdown := supervisor.shutdown
	supervisor.shutdown = nil
	supervisor.current = nil
	supervisor.mu.Unlock()
	if shutdown != nil {
		_ = shutdown()
	}
}

// stopLocked stops the running responder. A non-empty reason reports why the
// Host stopped advertising; replacing records passes an empty reason.
func (supervisor *Supervisor) stopLocked(reason string) {
	shutdown := supervisor.shutdown
	supervisor.shutdown = nil
	supervisor.current = nil
	if shutdown != nil {
		_ = shutdown()
	}
	if reason != "" {
		supervisor.logger.Info("Warren LAN discovery disabled", "reason", reason)
	}
}

func equalAddresses(left, right []net.IP) bool {
	if len(left) != len(right) {
		return false
	}
	for index := range left {
		if !left[index].Equal(right[index]) {
			return false
		}
	}
	return true
}
