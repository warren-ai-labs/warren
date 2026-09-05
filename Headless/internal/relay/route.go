package relay

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"path"
	"strings"
	"time"
)

// Route is the Relay-owned public HTTP/Upgrade route for one Host.
// It deliberately mirrors Relay's wire representation so the Host can keep
// only non-secret route metadata in its settings file.
type Route struct {
	ID               string   `json:"route_id"`
	PublicHostname   string   `json:"public_hostname"`
	HostID           string   `json:"host_id"`
	Generation       uint64   `json:"generation"`
	PathPrefix       string   `json:"path_prefix"`
	AuthMode         string   `json:"auth_mode"`
	Enabled          bool     `json:"enabled"`
	AllowCredentials bool     `json:"allow_credentials,omitempty"`
	AllowedMethods   []string `json:"allowed_methods,omitempty"`
	AllowedPaths     []string `json:"allowed_paths,omitempty"`
}

// Device is a client association issued by Relay for one Host. The ID is an
// opaque, non-secret handle suitable for display and revocation.
type Device struct {
	ID         string    `json:"id"`
	ClientID   string    `json:"client_id,omitempty"`
	CreatedAt  time.Time `json:"created_at"`
	LastSeenAt time.Time `json:"last_seen_at"`
}

// RouteClient performs authenticated route lifecycle calls against Relay.
// The token is held only in memory and is never included in a URL.
type RouteClient struct {
	baseURL string
	hostID  string
	token   string
	http    *http.Client
}

var ErrRouteNotFound = errors.New("Relay route not found")

// NewRouteClient validates the Relay origin and Host identity before any
// request is made. Redirects are disabled so the Host Secret cannot be sent
// to an alternate origin.
func NewRouteClient(baseURL, hostID, token string) (*RouteClient, error) {
	baseURL = strings.TrimRight(strings.TrimSpace(baseURL), "/")
	parsed, err := url.Parse(baseURL)
	if err != nil || parsed.Host == "" || parsed.User != nil || parsed.Fragment != "" || parsed.RawQuery != "" || parsed.Opaque != "" {
		return nil, errors.New("invalid Relay URL")
	}
	if parsed.Scheme != "http" && parsed.Scheme != "https" {
		return nil, errors.New("Relay URL must use http or https")
	}
	if strings.ContainsAny(parsed.Host+parsed.Path, "\r\n\x00") || strings.HasPrefix(parsed.Path, "//") {
		return nil, errors.New("invalid Relay URL")
	}
	for _, segment := range strings.Split(parsed.Path, "/") {
		if segment == "." || segment == ".." {
			return nil, errors.New("Relay URL path traversal is not allowed")
		}
	}
	hostID = strings.ToLower(strings.TrimSpace(hostID))
	if hostID == "" || strings.TrimSpace(token) == "" {
		return nil, errors.New("Relay Host ID and Host Secret are required")
	}
	return &RouteClient{
		baseURL: baseURL,
		hostID:  hostID,
		token:   token,
		http: &http.Client{CheckRedirect: func(_ *http.Request, _ []*http.Request) error {
			return http.ErrUseLastResponse
		}},
	}, nil
}

func (client *RouteClient) endpoint() string {
	return client.baseURL + "/v1/hosts/" + url.PathEscape(client.hostID) + "/route"
}

func (client *RouteClient) devicesEndpoint() string {
	return client.baseURL + "/v1/hosts/" + url.PathEscape(client.hostID) + "/devices"
}

// Devices returns the currently active client associations for this Host.
func (client *RouteClient) Devices(ctx context.Context) ([]Device, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, client.devicesEndpoint(), nil)
	if err != nil {
		return nil, err
	}
	request.Header.Set("Authorization", "Bearer "+client.token)
	response, err := client.http.Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return nil, responseError(response)
	}
	var value struct {
		Devices []Device `json:"devices"`
	}
	if err := json.NewDecoder(io.LimitReader(response.Body, 256*1024)).Decode(&value); err != nil {
		return nil, fmt.Errorf("decode Relay devices: %w", err)
	}
	return value.Devices, nil
}

// RevokeDevice permanently invalidates one client association.
func (client *RouteClient) RevokeDevice(ctx context.Context, deviceID string) error {
	deviceID = strings.TrimSpace(deviceID)
	if deviceID == "" {
		return errors.New("Relay device ID is required")
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodDelete, client.devicesEndpoint()+"/"+url.PathEscape(deviceID), nil)
	if err != nil {
		return err
	}
	request.Header.Set("Authorization", "Bearer "+client.token)
	response, err := client.http.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return responseError(response)
	}
	return nil
}

// Configure creates or updates the Host route. Nil fields preserve Relay's
// existing values; an omitted body asks Relay to allocate its default address.
func (client *RouteClient) Configure(ctx context.Context, route Route) (Route, error) {
	body := map[string]any{
		"enabled":   route.Enabled,
		"auth_mode": route.AuthMode,
	}
	if strings.TrimSpace(route.PublicHostname) != "" {
		body["public_hostname"] = strings.TrimSpace(route.PublicHostname)
	}
	if strings.TrimSpace(route.PathPrefix) != "" {
		body["path_prefix"] = strings.TrimSpace(route.PathPrefix)
	}
	if route.AllowCredentials {
		body["allow_credentials"] = true
	}
	if route.AllowedMethods != nil {
		body["allowed_methods"] = route.AllowedMethods
	}
	if route.AllowedPaths != nil {
		body["allowed_paths"] = route.AllowedPaths
	}
	return client.do(ctx, http.MethodPost, body)
}

// Get returns the current Relay route.
func (client *RouteClient) Get(ctx context.Context) (Route, error) {
	return client.do(ctx, http.MethodGet, nil)
}

// Disable marks the Relay route unavailable and closes public streams.
func (client *RouteClient) Disable(ctx context.Context) error {
	request, err := http.NewRequestWithContext(ctx, http.MethodDelete, client.endpoint(), nil)
	if err != nil {
		return err
	}
	request.Header.Set("Authorization", "Bearer "+client.token)
	response, err := client.http.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode == http.StatusNotFound {
		return ErrRouteNotFound
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return responseError(response)
	}
	return nil
}

func (client *RouteClient) do(ctx context.Context, method string, value any) (Route, error) {
	var body io.Reader
	if value != nil {
		data, err := json.Marshal(value)
		if err != nil {
			return Route{}, err
		}
		body = strings.NewReader(string(data))
	}
	request, err := http.NewRequestWithContext(ctx, method, client.endpoint(), body)
	if err != nil {
		return Route{}, err
	}
	request.Header.Set("Authorization", "Bearer "+client.token)
	if value != nil {
		request.Header.Set("Content-Type", "application/json")
	}
	response, err := client.http.Do(request)
	if err != nil {
		return Route{}, err
	}
	defer response.Body.Close()
	if response.StatusCode == http.StatusNotFound {
		return Route{}, ErrRouteNotFound
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return Route{}, responseError(response)
	}
	var route Route
	if err := json.NewDecoder(io.LimitReader(response.Body, 64*1024)).Decode(&route); err != nil {
		return Route{}, fmt.Errorf("decode Relay route: %w", err)
	}
	return route, nil
}

func responseError(response *http.Response) error {
	data, _ := io.ReadAll(io.LimitReader(response.Body, 8*1024))
	message := strings.TrimSpace(string(data))
	if message == "" {
		message = response.Status
	}
	return fmt.Errorf("Relay returned HTTP %d: %s", response.StatusCode, message)
}

// PublicURL derives the canonical browser address from Relay route metadata.
// IP/localhost deployments keep the Relay port and use the route path; DNS
// deployments use the route hostname and its configured path prefix. The
// returned path always ends in a slash so relative Web/PWA assets resolve
// inside a path-scoped route.
func (route Route) PublicURL(relayURL string) (string, error) {
	base, err := url.Parse(strings.TrimRight(strings.TrimSpace(relayURL), "/"))
	if err != nil || base.Host == "" || (base.Scheme != "http" && base.Scheme != "https") {
		return "", errors.New("invalid Relay URL")
	}
	host := strings.TrimSpace(route.PublicHostname)
	if host == "" {
		return "", errors.New("Relay route has no public hostname")
	}
	if net.ParseIP(host) != nil || strings.EqualFold(host, "localhost") {
		host = base.Host
	}
	prefix := path.Clean("/" + strings.TrimSpace(route.PathPrefix))
	if prefix == "." || prefix == "/" {
		prefix = "/"
	}
	basePath := strings.TrimRight(base.EscapedPath(), "/")
	publicPath := basePath + prefix
	if !strings.HasSuffix(publicPath, "/") {
		publicPath += "/"
	}
	return base.Scheme + "://" + host + publicPath, nil
}
