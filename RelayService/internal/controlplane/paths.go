package controlplane

import (
	"crypto/sha256"
	"encoding/base64"
	"net/url"
	"strings"
)

func relayID(publicURL string) string {
	digest := sha256.Sum256([]byte(publicURL))
	return base64.RawURLEncoding.EncodeToString(digest[:8])
}

func relayPathPrefix(publicURL string) string {
	parsed, err := url.Parse(strings.TrimSpace(publicURL))
	if err != nil {
		return ""
	}
	prefix := strings.TrimRight(parsed.EscapedPath(), "/")
	if prefix == "" || prefix == "." || prefix == "/" || !strings.HasPrefix(prefix, "/") {
		return ""
	}
	return prefix
}

func relayPublicOrigin(publicURL string) string {
	parsed, err := url.Parse(strings.TrimSpace(publicURL))
	if err != nil || parsed.Scheme == "" || parsed.Host == "" {
		return strings.TrimRight(strings.TrimSpace(publicURL), "/")
	}
	parsed.Path = ""
	parsed.RawPath = ""
	parsed.RawQuery = ""
	parsed.Fragment = ""
	return strings.TrimRight(parsed.String(), "/")
}

func (server *Server) publicPath(value string) string {
	value = "/" + strings.TrimLeft(value, "/")
	return strings.TrimRight(server.basePath, "/") + value
}

func canonicalChallenge(challenge relayChallenge, hostID string) string {
	return strings.Join([]string{challenge.Version, challenge.RelayID, challenge.Nonce, hostID, strings.Join(challenge.Capabilities, ",")}, "|")
}

func originAllowed(configured, origin string) bool {
	if strings.TrimSpace(origin) == "" {
		// Native clients and Host connectors do not send a browser Origin.
		return true
	}
	for _, allowed := range strings.Split(configured, ",") {
		if strings.TrimSpace(allowed) != "" && secureEqual(strings.TrimSpace(allowed), origin) {
			return true
		}
	}
	return false
}
