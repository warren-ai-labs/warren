package usage

import "strings"

// NormalizeModelID reduces a provider's model string to the identity used for
// price lookup. models.dev keys models by bare id, while the CLIs decorate that
// id with a routing prefix, a variant suffix, or a context-window marker.
//
// The rules mirror cc-switch's normalizeModelIdForPricing, which is proven
// against the same catalog:
//
//	anthropic/claude-opus-5   -> claude-opus-5   (routing prefix)
//	claude-opus-5[1m]         -> claude-opus-5   (context-window marker)
//	gpt-5.5:thinking          -> gpt-5.5         (variant suffix)
//	gemini-2.5-pro@20260101   -> gemini-2.5-pro-20260101
//
// The original string is stored alongside the normalized one so a model that
// still fails to match a price can be identified rather than vanishing into an
// unpriced total.
func NormalizeModelID(value string) string {
	normalized := strings.TrimSpace(value)
	if normalized == "" {
		return ""
	}
	// A routing prefix names the gateway, not the model being billed.
	if index := strings.LastIndex(normalized, "/"); index >= 0 {
		normalized = normalized[index+1:]
	}
	// A variant suffix selects a mode of the same priced model.
	if index := strings.Index(normalized, ":"); index >= 0 {
		normalized = normalized[:index]
	}
	normalized = strings.ReplaceAll(normalized, "@", "-")
	normalized = strings.ToLower(strings.TrimSpace(normalized))
	// A context-window marker is a capability flag, not a separate catalog
	// entry. Warren's own model id for the long-context Opus carries one.
	normalized = strings.TrimSuffix(normalized, "[1m]")
	return strings.TrimSpace(normalized)
}
