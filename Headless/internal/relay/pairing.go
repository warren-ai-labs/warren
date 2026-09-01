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

// PairingResult is the safe, client-facing portion of a Relay share action.
// Access capabilities and pairing codes are deliberately omitted: the daemon
// uses them internally and returns only the opaque URL that can be copied or
// rendered as a QR code by Desktop.
type PairingResult struct {
	PairingURL string `json:"pairing_url"`
	ExpiresIn  int    `json:"expires_in"`
	ExpiresAt  string `json:"expires_at,omitempty"`
	Reusable   bool   `json:"reusable"`
}

// PairingClient performs the two authenticated Relay calls needed to create a
// shareable invite. The Host Secret remains in the daemon process and is never
// serialized into PairingResult.
type PairingClient struct {
	baseURL string
	hostID  string
	token   string
	http    *http.Client
}

type pairingExchange struct {
	WebURL     string `json:"web_url"`
	PairingURL string `json:"pairing_url"`
	ExpiresIn  int    `json:"pairing_expires_in"`
	ExpiresAt  string `json:"pairing_expires_at"`
}

// NewPairingClient validates the Relay origin and Host identity before any
// request is made. Redirects are disabled so the Host Secret cannot be sent
// to an alternate origin.
func NewPairingClient(baseURL, hostID, token string) (*PairingClient, error) {
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
	hostID = strings.TrimSpace(hostID)
	if hostID == "" || strings.TrimSpace(token) == "" {
		return nil, errors.New("Relay Host ID and Host Secret are required")
	}
	return &PairingClient{
		baseURL: baseURL,
		hostID:  hostID,
		token:   token,
		http: &http.Client{Timeout: 15 * time.Second, CheckRedirect: func(_ *http.Request, _ []*http.Request) error {
			return http.ErrUseLastResponse
		}},
	}, nil
}

// Share starts a reusable pairing window and exchanges the resulting code for
// a single opaque invite URL. The Relay remains the authority for expiry and
// invalidation when a new pairing code is generated.
func (client *PairingClient) Share(ctx context.Context) (PairingResult, error) {
	const attempts = 20
	for attempt := 0; attempt < attempts; attempt++ {
		startRequest, err := http.NewRequestWithContext(ctx, http.MethodPost, client.baseURL+"/v1/hosts/"+url.PathEscape(client.hostID)+"/pairing", nil)
		if err != nil {
			return PairingResult{}, err
		}
		startRequest.Header.Set("Authorization", "Bearer "+client.token)
		startResponse, err := client.http.Do(startRequest)
		if err != nil {
			return PairingResult{}, err
		}
		if startResponse.StatusCode == http.StatusConflict {
			data, _ := io.ReadAll(io.LimitReader(startResponse.Body, 8*1024))
			startResponse.Body.Close()
			if strings.TrimSpace(strings.ToLower(string(data))) == "host offline" && attempt+1 < attempts {
				timer := time.NewTimer(250 * time.Millisecond)
				select {
				case <-ctx.Done():
					timer.Stop()
					return PairingResult{}, ctx.Err()
				case <-timer.C:
				}
				continue
			}
			message := strings.TrimSpace(string(data))
			if message == "" {
				message = startResponse.Status
			}
			return PairingResult{}, fmt.Errorf("Relay returned HTTP %d: %s", startResponse.StatusCode, message)
		}
		if startResponse.StatusCode < 200 || startResponse.StatusCode >= 300 {
			err = responseError(startResponse)
			startResponse.Body.Close()
			return PairingResult{}, err
		}
		var start struct {
			Code string `json:"pairing_code"`
		}
		err = json.NewDecoder(io.LimitReader(startResponse.Body, 64*1024)).Decode(&start)
		startResponse.Body.Close()
		if err != nil || strings.TrimSpace(start.Code) == "" {
			if err == nil {
				err = errors.New("Relay pairing did not return a code")
			}
			return PairingResult{}, err
		}
		return client.exchange(ctx, start.Code)
	}
	return PairingResult{}, errors.New("Relay Host did not come online in time")
}

func (client *PairingClient) exchange(ctx context.Context, code string) (PairingResult, error) {
	body, err := json.Marshal(map[string]string{"host_id": client.hostID, "pairing_code": code})
	if err != nil {
		return PairingResult{}, err
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, client.baseURL+"/v1/pair", strings.NewReader(string(body)))
	if err != nil {
		return PairingResult{}, err
	}
	request.Header.Set("Content-Type", "application/json")
	response, err := client.http.Do(request)
	if err != nil {
		return PairingResult{}, err
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return PairingResult{}, responseError(response)
	}
	var value pairingExchange
	if err := json.NewDecoder(response.Body).Decode(&value); err != nil {
		return PairingResult{}, err
	}
	link := strings.TrimSpace(value.PairingURL)
	if link == "" {
		link = strings.TrimSpace(value.WebURL)
	}
	if link == "" || !sameRelayPairingOrigin(client.baseURL, link) {
		return PairingResult{}, errors.New("Relay pairing did not return a link")
	}
	if value.ExpiresIn <= 0 {
		value.ExpiresIn = 7 * 24 * 60 * 60
	}
	return PairingResult{PairingURL: link, ExpiresIn: value.ExpiresIn, ExpiresAt: strings.TrimSpace(value.ExpiresAt), Reusable: true}, nil
}

// sameRelayPairingOrigin rejects a compromised or misconfigured Relay that
// attempts to hand the daemon a link on another origin. Only the Relay's own
// opaque invite (or the legacy host-scoped path) is accepted; query strings
// are not needed for either form and could smuggle credentials into history.
func sameRelayPairingOrigin(baseURL, link string) bool {
	base, baseErr := url.Parse(baseURL)
	candidate, candidateErr := url.Parse(strings.TrimSpace(link))
	if baseErr != nil || candidateErr != nil || base.Host == "" || candidate.Host == "" || candidate.User != nil || candidate.RawQuery != "" || candidate.Fragment != "" {
		return false
	}
	if !strings.EqualFold(base.Scheme, candidate.Scheme) || !strings.EqualFold(base.Host, candidate.Host) {
		return false
	}
	basePath := strings.TrimRight(base.EscapedPath(), "/")
	candidatePath := strings.TrimRight(candidate.EscapedPath(), "/")
	if basePath != "" && !strings.HasPrefix(candidatePath, basePath+"/") {
		return false
	}
	relative := strings.TrimPrefix(candidatePath, basePath)
	parts := strings.Split(strings.Trim(relative, "/"), "/")
	return len(parts) == 2 && (parts[0] == "invite" || parts[0] == "h") && parts[1] != ""
}
