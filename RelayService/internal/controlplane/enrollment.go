package controlplane

import (
	"crypto/rand"
	"errors"
	"strings"
	"time"
)

const (
	enrollmentCodeLength = 16
	enrollmentCodeGroup  = 4
	// The alphabet is deliberately upper-case and omits characters that are
	// easy to confuse when a code is read over the phone or copied from a
	// terminal. Hyphens are presentation-only and are not part of the secret.
	enrollmentCodeAlphabet   = "ABCDEFGHJKMNPQRSTVWXYZ"
	defaultEnrollmentKeyTTL  = 24 * time.Hour
	defaultEnrollmentKeyUses = 1
	maxEnrollmentKeyBatch    = 1000
	maxEnrollmentKeyUses     = 1000
)

type enrollmentKeyRecord struct {
	ID        string    `json:"id"`
	Hash      string    `json:"hash"`
	Label     string    `json:"label,omitempty"`
	CreatedAt time.Time `json:"created_at"`
	ExpiresAt time.Time `json:"expires_at"`
	MaxUses   int       `json:"max_uses"`
	UsedUses  int       `json:"used_uses"`
	RevokedAt time.Time `json:"revoked_at,omitempty"`
}

type enrollmentKey struct {
	ID        string    `json:"id"`
	Code      string    `json:"key"`
	Label     string    `json:"label,omitempty"`
	CreatedAt time.Time `json:"created_at"`
	ExpiresAt time.Time `json:"expires_at"`
	MaxUses   int       `json:"max_uses"`
	UsedUses  int       `json:"used_uses"`
}

func normalizeEnrollmentCode(raw string) (string, error) {
	value := strings.ToUpper(strings.TrimSpace(raw))
	value = strings.ReplaceAll(value, "-", "")
	if len(value) != enrollmentCodeLength {
		return "", errors.New("enrollment key must contain 16 letters")
	}
	for _, character := range value {
		if !strings.ContainsRune(enrollmentCodeAlphabet, character) {
			return "", errors.New("enrollment key contains an invalid character")
		}
	}
	return value, nil
}

func formatEnrollmentCode(raw string) string {
	var builder strings.Builder
	for index, character := range raw {
		if index > 0 && index%enrollmentCodeGroup == 0 {
			builder.WriteByte('-')
		}
		builder.WriteRune(character)
	}
	return builder.String()
}

func newEnrollmentCode() (string, error) {
	value := make([]byte, enrollmentCodeLength)
	// Rejection sampling avoids bias from mapping a byte directly onto the
	// alphabet. The alphabet is small enough that the loop is effectively
	// constant-time while still using crypto/rand for every generated key.
	limit := byte(256 - (256 % len(enrollmentCodeAlphabet)))
	for index := range value {
		for {
			var sample [1]byte
			if _, err := rand.Read(sample[:]); err != nil {
				return "", err
			}
			if sample[0] >= limit {
				continue
			}
			value[index] = enrollmentCodeAlphabet[int(sample[0])%len(enrollmentCodeAlphabet)]
			break
		}
	}
	return string(value), nil
}

func newEnrollmentKeyID() (string, error) {
	value := make([]byte, 8)
	if _, err := rand.Read(value); err != nil {
		return "", err
	}
	const hex = "0123456789abcdef"
	encoded := make([]byte, len(value)*2)
	for index, item := range value {
		encoded[index*2] = hex[item>>4]
		encoded[index*2+1] = hex[item&0x0f]
	}
	return string(encoded), nil
}
