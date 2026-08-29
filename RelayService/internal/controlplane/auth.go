package controlplane

import (
	"crypto/ed25519"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"strings"
	"sync"
	"time"
)

const capabilityAudience = "warren-relay-stream"
const capabilityIssuer = "warren-relay"

var supportedCapabilityScopes = map[string]struct{}{
	"control":    {},
	"tunnel":     {},
	"p2p-signal": {},
	"admin":      {},
}

// tokenClaims is the Relay capability payload. Scope is an array even when a
// caller asks for one scope; this prevents a signed string from being
// accidentally interpreted as multiple permissions by another component.
type tokenClaims struct {
	Issuer     string   `json:"iss,omitempty"`
	Audience   string   `json:"aud,omitempty"`
	HostID     string   `json:"host_id"`
	Scope      []string `json:"scope"`
	Generation uint64   `json:"generation"`
	RouteID    string   `json:"route_id,omitempty"`
	ClientID   string   `json:"client_id,omitempty"`
	JTI        string   `json:"jti,omitempty"`
	Expiry     int64    `json:"exp"`
	KeyID      string   `json:"kid,omitempty"`
}

// UnmarshalJSON accepts the pre-RFC single-string scope for a bounded
// compatibility window while always exposing an array to callers.
func (claims *tokenClaims) UnmarshalJSON(data []byte) error {
	var value struct {
		Issuer     string          `json:"iss,omitempty"`
		Audience   string          `json:"aud,omitempty"`
		HostID     string          `json:"host_id"`
		Scope      json.RawMessage `json:"scope"`
		Generation uint64          `json:"generation"`
		RouteID    string          `json:"route_id,omitempty"`
		ClientID   string          `json:"client_id,omitempty"`
		JTI        string          `json:"jti,omitempty"`
		Expiry     int64           `json:"exp"`
		KeyID      string          `json:"kid,omitempty"`
	}
	if err := json.Unmarshal(data, &value); err != nil {
		return err
	}
	var scopes []string
	if len(value.Scope) > 0 && string(value.Scope) != "null" {
		if err := json.Unmarshal(value.Scope, &scopes); err != nil {
			var scope string
			if err := json.Unmarshal(value.Scope, &scope); err != nil {
				return err
			}
			if scope != "" {
				scopes = []string{scope}
			}
		}
	}
	*claims = tokenClaims{Issuer: value.Issuer, Audience: value.Audience, HostID: value.HostID, Scope: scopes, Generation: value.Generation, RouteID: value.RouteID, ClientID: value.ClientID, JTI: value.JTI, Expiry: value.Expiry, KeyID: value.KeyID}
	return nil
}

func (claims tokenClaims) hasScope(scope string) bool {
	for _, value := range claims.Scope {
		if value == scope {
			return true
		}
	}
	return false
}

type tokenSigner struct {
	mu      sync.RWMutex
	keyID   string
	keys    map[string]ed25519.PrivateKey
	public  map[string]ed25519.PublicKey
	now     func() time.Time
	revoked map[string]time.Time
}

func newTokenSigner(key []byte) (*tokenSigner, error) {
	if len(key) < ed25519.SeedSize {
		return nil, errors.New("WARREN_RELAY_SIGNING_KEY must contain at least 32 bytes")
	}
	// Environment configuration historically accepted arbitrary byte strings;
	// use the first seed-sized portion while keeping the resulting key an
	// Ed25519 key. The 32-byte seed is the canonical persisted representation.
	private := ed25519.NewKeyFromSeed(key[:ed25519.SeedSize])
	public := private.Public().(ed25519.PublicKey)
	keyID := keyFingerprint(public)
	return &tokenSigner{
		keyID:   keyID,
		keys:    map[string]ed25519.PrivateKey{keyID: private},
		public:  map[string]ed25519.PublicKey{keyID: append(ed25519.PublicKey(nil), public...)},
		now:     time.Now,
		revoked: make(map[string]time.Time),
	}, nil
}

func keyFingerprint(key ed25519.PublicKey) string {
	digest := sha256.Sum256(key)
	return base64.RawURLEncoding.EncodeToString(digest[:8])
}

func randomToken(byteCount int) (string, error) {
	bytes := make([]byte, byteCount)
	if _, err := rand.Read(bytes); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(bytes), nil
}

// rotate installs an overlapping signing key and makes it the issuer. Older
// public keys remain verifiable until explicitly removed with removeKey.
func (signer *tokenSigner) rotate(keyID string, key []byte) error {
	if len(key) < ed25519.SeedSize {
		return errors.New("signing key must contain at least 32 bytes")
	}
	private := ed25519.NewKeyFromSeed(key[:ed25519.SeedSize])
	public := private.Public().(ed25519.PublicKey)
	if strings.TrimSpace(keyID) == "" {
		keyID = keyFingerprint(public)
	}
	signer.mu.Lock()
	defer signer.mu.Unlock()
	signer.keys[keyID] = private
	signer.public[keyID] = append(ed25519.PublicKey(nil), public...)
	signer.keyID = keyID
	return nil
}

func (signer *tokenSigner) removeKey(keyID string) {
	signer.mu.Lock()
	defer signer.mu.Unlock()
	if keyID == signer.keyID {
		return
	}
	delete(signer.keys, keyID)
	delete(signer.public, keyID)
}

// issue retains the small historical helper used by Relay tests while
// emitting a complete control capability under the v2 claims contract.
func (signer *tokenSigner) issue(hostID, scope string, generation uint64, ttl time.Duration) (string, error) {
	if _, ok := supportedCapabilityScopes[scope]; !ok {
		return "", errors.New("unsupported capability scope")
	}
	return signer.issueCapability(tokenClaims{
		HostID: hostID, Scope: []string{scope}, Generation: generation,
		Expiry: signer.now().Add(ttl).Unix(),
	})
}

func (signer *tokenSigner) issueCapability(claims tokenClaims) (string, error) {
	if strings.TrimSpace(claims.HostID) == "" || len(claims.Scope) == 0 {
		return "", errors.New("host and scope are required")
	}
	for _, scope := range claims.Scope {
		if _, ok := supportedCapabilityScopes[scope]; !ok {
			return "", errors.New("unsupported capability scope")
		}
	}
	if claims.Issuer == "" {
		claims.Issuer = "warren-relay"
	}
	if claims.Audience == "" {
		claims.Audience = capabilityAudience
	}
	if claims.JTI == "" {
		jti, err := randomToken(16)
		if err != nil {
			return "", err
		}
		claims.JTI = jti
	}
	if claims.Expiry <= signer.now().Unix() {
		return "", errors.New("capability expiry is required")
	}
	signer.mu.RLock()
	keyID := signer.keyID
	private := append(ed25519.PrivateKey(nil), signer.keys[keyID]...)
	signer.mu.RUnlock()
	if len(private) != ed25519.PrivateKeySize {
		return "", errors.New("signing key unavailable")
	}
	claims.KeyID = keyID
	payload, err := json.Marshal(claims)
	if err != nil {
		return "", err
	}
	encoded := base64.RawURLEncoding.EncodeToString(payload)
	signature := ed25519.Sign(private, []byte(encoded))
	return encoded + "." + base64.RawURLEncoding.EncodeToString(signature), nil
}

func (signer *tokenSigner) verify(token, hostID, scope string) (tokenClaims, error) {
	parts := strings.Split(token, ".")
	if len(parts) != 2 {
		return tokenClaims{}, errors.New("invalid token")
	}
	provided, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil || len(provided) != ed25519.SignatureSize {
		return tokenClaims{}, errors.New("invalid token signature")
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return tokenClaims{}, errors.New("invalid token payload")
	}
	var claims tokenClaims
	if json.Unmarshal(payload, &claims) != nil || (hostID != "" && claims.HostID != hostID) || !claims.hasScope(scope) {
		return tokenClaims{}, errors.New("invalid token claims")
	}
	if claims.Issuer != capabilityIssuer || claims.Audience != capabilityAudience {
		return tokenClaims{}, errors.New("invalid token audience")
	}
	if strings.TrimSpace(claims.JTI) == "" {
		return tokenClaims{}, errors.New("invalid token jti")
	}
	signer.mu.RLock()
	public := append(ed25519.PublicKey(nil), signer.public[claims.KeyID]...)
	// Tokens issued before key IDs were persisted are checked against the
	// current key only; all newly issued capabilities carry kid.
	if len(public) == 0 && claims.KeyID == "" {
		public = append(ed25519.PublicKey(nil), signer.public[signer.keyID]...)
	}
	signer.mu.RUnlock()
	if len(public) != ed25519.PublicKeySize || !ed25519.Verify(public, []byte(parts[0]), provided) {
		return tokenClaims{}, errors.New("invalid token signature")
	}
	now := signer.now()
	if now.Unix() >= claims.Expiry {
		return tokenClaims{}, errors.New("token expired")
	}
	signer.mu.Lock()
	if until, revoked := signer.revoked[claims.JTI]; revoked {
		if until.IsZero() || now.Before(until) {
			signer.mu.Unlock()
			return tokenClaims{}, errors.New("token revoked")
		}
		delete(signer.revoked, claims.JTI)
	}
	signer.mu.Unlock()
	return claims, nil
}

func (signer *tokenSigner) currentKeyID() string {
	signer.mu.RLock()
	defer signer.mu.RUnlock()
	return signer.keyID
}

func (signer *tokenSigner) currentPublicKey() (string, ed25519.PublicKey) {
	signer.mu.RLock()
	defer signer.mu.RUnlock()
	key := append(ed25519.PublicKey(nil), signer.public[signer.keyID]...)
	return signer.keyID, key
}

func (signer *tokenSigner) revokeJTI(jti string, until time.Time) {
	if strings.TrimSpace(jti) == "" {
		return
	}
	signer.mu.Lock()
	signer.revoked[jti] = until
	signer.mu.Unlock()
}

func (signer *tokenSigner) publicKeys() map[string]ed25519.PublicKey {
	signer.mu.RLock()
	defer signer.mu.RUnlock()
	result := make(map[string]ed25519.PublicKey, len(signer.public))
	for id, key := range signer.public {
		result[id] = append(ed25519.PublicKey(nil), key...)
	}
	return result
}

func challengeProof(secret, canonical string) string {
	mac := hmac.New(sha256.New, []byte(secret))
	_, _ = mac.Write([]byte(canonical))
	return base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}

func verifyChallengeProof(secret, canonical, proof string) bool {
	provided, err := base64.RawURLEncoding.DecodeString(strings.TrimSpace(proof))
	if err != nil {
		return false
	}
	mac := hmac.New(sha256.New, []byte(secret))
	_, _ = mac.Write([]byte(canonical))
	return hmac.Equal(provided, mac.Sum(nil))
}
