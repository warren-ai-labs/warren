package server

import (
	"context"
	"errors"
	"strings"
	"sync"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/relay"
	"github.com/abcdlsj/warren/Headless/internal/settings"
)

// PublicAccessService is the single Host-owned use-case implementation for
// both the local REST adapter and the relayed Warren RPC adapter.
type PublicAccessService struct {
	host        *Service
	routeClient func() (*relay.RouteClient, error)
	relayStart  func() error
	mu          sync.Mutex
}

func newPublicAccessService(host *Service, routeClient func() (*relay.RouteClient, error), relayStart func() error) *PublicAccessService {
	return &PublicAccessService{host: host, routeClient: routeClient, relayStart: relayStart}
}

func (s *PublicAccessService) Status(ctx context.Context) api.PublicAccessStatus {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.statusLocked(ctx)
}

func (s *PublicAccessService) Enable(ctx context.Context, request api.PublicAccessEnableRequest) (api.PublicAccessStatus, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.relayStart != nil {
		if err := s.relayStart(); err != nil {
			return api.PublicAccessStatus{}, err
		}
	}
	current := s.host.PublicTunnelSettingsSnapshot()
	route := publicRouteFromSettings(current, true)
	applyPublicAccessRequest(&route, request.PublicHostname, request.PathPrefix)
	configured, err := s.configureLocked(ctx, route)
	if err != nil {
		return api.PublicAccessStatus{}, err
	}
	if err := s.persistRouteLocked(configured, true); err != nil {
		return api.PublicAccessStatus{}, err
	}
	return s.statusForRouteLocked(configured, true), nil
}

func (s *PublicAccessService) Test(ctx context.Context, request api.PublicAccessTestRequest) (api.PublicAccessStatus, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	current := s.host.PublicTunnelSettingsSnapshot()
	route := publicRouteFromSettings(current, current.Enabled)
	applyPublicAccessRequest(&route, request.PublicHostname, request.PathPrefix)
	var err error
	if request.PublicHostname != nil || request.PathPrefix != nil {
		route.Enabled = false
		route, err = s.configureLocked(ctx, route)
	} else {
		route, err = s.getLocked(ctx)
	}
	if err != nil {
		return api.PublicAccessStatus{}, err
	}
	if err := s.persistRouteLocked(route, current.Enabled); err != nil {
		return api.PublicAccessStatus{}, err
	}
	return s.statusForRouteLocked(route, current.Enabled), nil
}

func (s *PublicAccessService) Disable(ctx context.Context) (api.PublicAccessStatus, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	client, err := s.clientLocked()
	if err != nil {
		return api.PublicAccessStatus{}, err
	}
	if err := client.Disable(ctx); err != nil && !errors.Is(err, relay.ErrRouteNotFound) {
		return api.PublicAccessStatus{}, err
	}
	current := s.host.PublicTunnelSettingsSnapshot()
	current.Enabled = false
	if err := s.host.UpdatePublicTunnelSettings(current); err != nil {
		return api.PublicAccessStatus{}, err
	}
	return s.statusFromSettingsLocked(), nil
}

func (s *PublicAccessService) Reset(ctx context.Context) (api.PublicAccessStatus, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if client, err := s.clientLocked(); err == nil {
		if disableErr := client.Disable(ctx); disableErr != nil && !errors.Is(disableErr, relay.ErrRouteNotFound) {
			return api.PublicAccessStatus{}, disableErr
		}
	}
	if err := s.host.UpdatePublicTunnelSettings(settings.PublicTunnelSettings{}); err != nil {
		return api.PublicAccessStatus{}, err
	}
	return s.statusFromSettingsLocked(), nil
}

func (s *PublicAccessService) Restart(ctx context.Context) (api.PublicAccessStatus, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	current := s.host.PublicTunnelSettingsSnapshot()
	configured, err := s.configureLocked(ctx, publicRouteFromSettings(current, true))
	if err != nil {
		return api.PublicAccessStatus{}, err
	}
	if err := s.persistRouteLocked(configured, true); err != nil {
		return api.PublicAccessStatus{}, err
	}
	return s.statusForRouteLocked(configured, true), nil
}

func (s *PublicAccessService) configureLocked(ctx context.Context, route relay.Route) (relay.Route, error) {
	client, err := s.clientLocked()
	if err != nil {
		return relay.Route{}, err
	}
	return client.Configure(ctx, route)
}

func (s *PublicAccessService) getLocked(ctx context.Context) (relay.Route, error) {
	client, err := s.clientLocked()
	if err != nil {
		return relay.Route{}, err
	}
	return client.Get(ctx)
}

func (s *PublicAccessService) clientLocked() (*relay.RouteClient, error) {
	if s == nil || s.host == nil {
		return nil, errors.New("Public Access service is unavailable")
	}
	if s.routeClient == nil {
		return nil, errors.New("Relay route is not configured")
	}
	return s.routeClient()
}

func (s *PublicAccessService) persistRouteLocked(route relay.Route, enabled bool) error {
	return s.host.UpdatePublicTunnelSettings(settings.PublicTunnelSettings{
		Enabled:        enabled,
		RouteID:        route.ID,
		Owner:          route.HostID,
		PublicHostname: route.PublicHostname,
		PathPrefix:     route.PathPrefix,
		AuthMode:       route.AuthMode,
	})
}

func (s *PublicAccessService) statusLocked(ctx context.Context) api.PublicAccessStatus {
	if s == nil || s.host == nil {
		return api.PublicAccessStatus{Error: "Public Access service is unavailable"}
	}
	status := s.statusFromSettingsLocked()
	if s.routeClient == nil {
		return status
	}
	client, err := s.routeClient()
	if err != nil {
		if status.Enabled {
			status.Error = err.Error()
		}
		return status
	}
	route, err := client.Get(ctx)
	if err != nil {
		if !errors.Is(err, relay.ErrRouteNotFound) {
			status.Error = err.Error()
		}
		return status
	}
	return s.statusForRouteLocked(route, route.Enabled)
}

func (s *PublicAccessService) statusFromSettingsLocked() api.PublicAccessStatus {
	current := s.host.SettingsSnapshot()
	return api.PublicAccessStatus{
		RelayURL:       current.Relay.URL,
		HostID:         current.Relay.HostID,
		RouteID:        current.PublicTunnel.RouteID,
		PublicHostname: current.PublicTunnel.PublicHostname,
		PathPrefix:     current.PublicTunnel.PathPrefix,
		AuthMode:       current.PublicTunnel.AuthMode,
		Enabled:        current.PublicTunnel.Enabled,
	}
}

func (s *PublicAccessService) statusForRouteLocked(route relay.Route, enabled bool) api.PublicAccessStatus {
	status := s.statusFromSettingsLocked()
	status.Authenticated = true
	status.RouteID = route.ID
	status.PublicHostname = route.PublicHostname
	status.PathPrefix = route.PathPrefix
	status.AuthMode = route.AuthMode
	status.Enabled = enabled
	status.Running = enabled && route.Enabled
	if status.Running {
		current := s.host.SettingsSnapshot()
		if endpoint, endpointErr := route.PublicURL(current.Relay.URL); endpointErr == nil {
			status.PublicEndpoint = endpoint
		} else {
			status.Error = endpointErr.Error()
			status.Running = false
		}
	}
	return status
}

func publicRouteFromSettings(current settings.PublicTunnelSettings, enabled bool) relay.Route {
	return relay.Route{
		ID:             current.RouteID,
		PublicHostname: current.PublicHostname,
		PathPrefix:     current.PathPrefix,
		AuthMode:       "public",
		Enabled:        enabled,
	}
}

func applyPublicAccessRequest(route *relay.Route, publicHostname, pathPrefix *string) {
	if publicHostname != nil {
		route.PublicHostname = strings.TrimSpace(*publicHostname)
	}
	if pathPrefix != nil {
		route.PathPrefix = strings.TrimSpace(*pathPrefix)
	}
}
