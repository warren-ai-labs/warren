package relay

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// LiveActivitySession is the Host-owned projection for one Session. Relay
// uses the session ID to select the registered ActivityKit push token and
// keeps the remaining fields opaque until it builds the APNs content state.
type LiveActivitySession struct {
	ID         string `json:"id"`
	Title      string `json:"title,omitempty"`
	Connection string `json:"connection"`
	Activity   string `json:"activity,omitempty"`
	Attention  bool   `json:"attention,omitempty"`
}

// LiveActivitySnapshot is a complete Host snapshot. Sending a complete
// projection lets Relay end an Activity whose Session was deleted without
// requiring Relay to understand Warren's roster protocol.
type LiveActivitySnapshot struct {
	Connection            string                `json:"connection"`
	ActiveSessionCount    int                   `json:"activeSessionCount"`
	WorkingSessionCount   int                   `json:"workingSessionCount"`
	AttentionSessionCount int                   `json:"attentionSessionCount"`
	Sessions              []LiveActivitySession `json:"sessions"`
	UpdatedAt             time.Time             `json:"updatedAt"`
}

// LiveActivityClient publishes Host snapshots to an enrolled Relay. The Host
// Secret is kept in the client and is sent only as an Authorization header;
// redirects are disabled so it cannot leave the configured Relay origin.
type LiveActivityClient struct {
	baseURL string
	hostID  string
	token   string
	http    *http.Client
}

// NewLiveActivityClient validates the Relay origin and Host identity before a
// request is made. It mirrors RouteClient's URL policy and intentionally does
// not infer a local listener or a WebSocket path.
func NewLiveActivityClient(baseURL, hostID, token string) (*LiveActivityClient, error) {
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
	return &LiveActivityClient{
		baseURL: baseURL,
		hostID:  hostID,
		token:   token,
		http: &http.Client{
			Timeout: 10 * time.Second,
			CheckRedirect: func(_ *http.Request, _ []*http.Request) error {
				return http.ErrUseLastResponse
			},
		},
	}, nil
}

func (client *LiveActivityClient) endpoint() string {
	return client.baseURL + "/v1/hosts/" + url.PathEscape(client.hostID) + "/live-activities"
}

// Publish sends one complete snapshot. A Relay without APNs credentials may
// accept the snapshot and report zero deliveries; that keeps Host lifecycle
// independent from optional mobile notification configuration.
func (client *LiveActivityClient) Publish(ctx context.Context, snapshot LiveActivitySnapshot) error {
	if client == nil {
		return errors.New("Relay live activity client is nil")
	}
	data, err := json.Marshal(snapshot)
	if err != nil {
		return err
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, client.endpoint(), strings.NewReader(string(data)))
	if err != nil {
		return err
	}
	request.Header.Set("Authorization", "Bearer "+client.token)
	request.Header.Set("Content-Type", "application/json")
	response, err := client.http.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		body, _ := io.ReadAll(io.LimitReader(response.Body, 8*1024))
		message := strings.TrimSpace(string(body))
		if message == "" {
			message = response.Status
		}
		return fmt.Errorf("Relay returned HTTP %d: %s", response.StatusCode, message)
	}
	return nil
}
