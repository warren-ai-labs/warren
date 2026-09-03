package controlplane

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

var errAPNsTokenExpired = errors.New("APNs live activity token is no longer valid")

// apnsSender owns the Relay-side APNs Provider API credentials. The private
// key is retained only in memory; Config is never serialized to the registry.
type apnsSender struct {
	keyID    string
	teamID   string
	topic    string
	key      *ecdsa.PrivateKey
	endpoint string
	http     *http.Client
	now      func() time.Time

	mu          sync.Mutex
	jwt         string
	jwtIssuedAt int64
}

func newAPNsSender(config Config) (*apnsSender, error) {
	values := []string{
		strings.TrimSpace(config.APNsKeyID),
		strings.TrimSpace(config.APNsTeamID),
		strings.TrimSpace(config.APNsBundleID),
		strings.TrimSpace(string(config.APNsPrivateKey)),
	}
	hasConfiguration := false
	for _, value := range values {
		if value != "" {
			hasConfiguration = true
			break
		}
	}
	if !hasConfiguration {
		return nil, nil
	}
	if values[0] == "" || values[1] == "" || values[2] == "" || values[3] == "" {
		return nil, errors.New("APNs requires key ID, team ID, bundle ID, and private key")
	}
	key, err := parseAPNsPrivateKey(config.APNsPrivateKey)
	if err != nil {
		return nil, fmt.Errorf("parse APNs private key: %w", err)
	}
	endpoint := strings.TrimRight(strings.TrimSpace(config.APNsEndpoint), "/")
	if endpoint == "" {
		if config.APNsProduction {
			endpoint = "https://api.push.apple.com"
		} else {
			endpoint = "https://api.sandbox.push.apple.com"
		}
	}
	parsed, err := url.Parse(endpoint)
	if err != nil || !strings.EqualFold(parsed.Scheme, "https") || parsed.Host == "" || parsed.User != nil || parsed.Path != "" || parsed.RawPath != "" || parsed.RawQuery != "" || parsed.Fragment != "" {
		return nil, errors.New("APNs endpoint must be an HTTPS origin")
	}
	client := config.APNsHTTPClient
	if client == nil {
		client = &http.Client{
			Timeout: 15 * time.Second,
			CheckRedirect: func(_ *http.Request, _ []*http.Request) error {
				return http.ErrUseLastResponse
			},
		}
	}
	return &apnsSender{
		keyID:    values[0],
		teamID:   values[1],
		topic:    values[2] + ".push-type.liveactivity",
		key:      key,
		endpoint: endpoint,
		http:     client,
		now:      time.Now,
	}, nil
}

func parseAPNsPrivateKey(data []byte) (*ecdsa.PrivateKey, error) {
	block, _ := pem.Decode(data)
	if block == nil {
		return nil, errors.New("PEM block is missing")
	}
	if key, err := x509.ParsePKCS8PrivateKey(block.Bytes); err == nil {
		if ecdsaKey, ok := key.(*ecdsa.PrivateKey); ok {
			if ecdsaKey.Curve != elliptic.P256() {
				return nil, errors.New("APNs private key must use P-256")
			}
			return ecdsaKey, nil
		}
		return nil, errors.New("APNs private key is not an ECDSA key")
	}
	key, err := x509.ParseECPrivateKey(block.Bytes)
	if err != nil {
		return nil, errors.New("unsupported private key format")
	}
	if key.Curve != elliptic.P256() {
		return nil, errors.New("APNs private key must use P-256")
	}
	return key, nil
}

type apnsContentState struct {
	Connection            string `json:"connection"`
	ActiveSessionCount    int    `json:"activeSessionCount"`
	WorkingSessionCount   int    `json:"workingSessionCount"`
	AttentionSessionCount int    `json:"attentionSessionCount"`
	CurrentSessionTitle   string `json:"currentSessionTitle,omitempty"`
	// WarrenLiveActivityState uses Foundation's default Date Codable strategy,
	// which is seconds since Apple's 2001 reference date (not Unix time).
	UpdatedAt float64 `json:"updatedAt"`
}

const appleReferenceUnix = 978307200

func (sender *apnsSender) authorization(now time.Time) (string, error) {
	issuedAt := now.Unix()
	sender.mu.Lock()
	defer sender.mu.Unlock()
	if sender.jwt != "" && issuedAt-sender.jwtIssuedAt < 45*60 {
		return sender.jwt, nil
	}
	header, err := json.Marshal(map[string]string{"alg": "ES256", "kid": sender.keyID})
	if err != nil {
		return "", err
	}
	claims, err := json.Marshal(map[string]any{"iss": sender.teamID, "iat": issuedAt})
	if err != nil {
		return "", err
	}
	encodedHeader := base64.RawURLEncoding.EncodeToString(header)
	encodedClaims := base64.RawURLEncoding.EncodeToString(claims)
	message := encodedHeader + "." + encodedClaims
	hash := sha256.Sum256([]byte(message))
	r, s, err := ecdsa.Sign(rand.Reader, sender.key, hash[:])
	if err != nil {
		return "", err
	}
	var signature [64]byte
	r.FillBytes(signature[:32])
	s.FillBytes(signature[32:])
	token := message + "." + base64.RawURLEncoding.EncodeToString(signature[:])
	sender.jwt = token
	sender.jwtIssuedAt = issuedAt
	return token, nil
}

func (sender *apnsSender) send(token string, state apnsContentState, event string, relevance float64, now time.Time) error {
	if sender == nil {
		return errors.New("APNs is not configured")
	}
	authorization, err := sender.authorization(now)
	if err != nil {
		return err
	}
	if event == "" {
		event = "update"
	}
	if relevance < 0 {
		relevance = 0
	} else if relevance > 1 {
		relevance = 1
	}
	aps := map[string]any{
		"timestamp":       now.Unix(),
		"event":           event,
		"content-state":   state,
		"stale-date":      now.Add(time.Hour).Unix(),
		"relevance-score": relevance,
	}
	if event == "end" {
		aps["dismissal-date"] = now.Unix()
	}
	body, err := json.Marshal(map[string]any{"aps": aps})
	if err != nil {
		return err
	}
	if !validPushToken(token) {
		return errAPNsTokenExpired
	}
	endpoint := sender.endpoint + "/3/device/" + url.PathEscape(strings.ToLower(token))
	request, err := http.NewRequest(http.MethodPost, endpoint, strings.NewReader(string(body)))
	if err != nil {
		return err
	}
	request.Header.Set("authorization", "bearer "+authorization)
	request.Header.Set("apns-push-type", "liveactivity")
	request.Header.Set("apns-topic", sender.topic)
	request.Header.Set("apns-priority", "10")
	request.Header.Set("content-type", "application/json")
	response, err := sender.http.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode == http.StatusGone {
		return errAPNsTokenExpired
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		data, _ := io.ReadAll(io.LimitReader(response.Body, 8*1024))
		message := strings.TrimSpace(string(data))
		if message == "" {
			message = response.Status
		}
		return fmt.Errorf("APNs returned HTTP %d: %s", response.StatusCode, message)
	}
	return nil
}

func validPushToken(value string) bool {
	value = strings.TrimSpace(value)
	if len(value) < 2 || len(value) > 512 || len(value)%2 != 0 {
		return false
	}
	for _, character := range value {
		if (character < '0' || character > '9') && (character < 'a' || character > 'f') && (character < 'A' || character > 'F') {
			return false
		}
	}
	return true
}
