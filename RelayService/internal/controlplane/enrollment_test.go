package controlplane

import (
	"os"
	"strings"
	"testing"
	"time"
)

func TestEnrollmentCodeNormalizesAndFormats(t *testing.T) {
	canonical, err := normalizeEnrollmentCode(" abcd-efgh-jkmn-pqrs ")
	if err != nil || canonical != "ABCDEFGHJKMNPQRS" {
		t.Fatalf("normalizeEnrollmentCode = %q, %v", canonical, err)
	}
	if got := formatEnrollmentCode(canonical); got != "ABCD-EFGH-JKMN-PQRS" {
		t.Fatalf("formatEnrollmentCode = %q", got)
	}
	for _, value := range []string{"", "ABC", "AAAA-BBBB-CCCC-DDD0", "AAAA-BBBB-CCCC-DDDD-EEEE"} {
		if _, err := normalizeEnrollmentCode(value); err == nil {
			t.Fatalf("normalizeEnrollmentCode(%q) accepted invalid input", value)
		}
	}
}

func TestEnrollmentKeyUsesAndExpiry(t *testing.T) {
	registry, err := newRegistry("")
	if err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 9, 4, 0, 0, 0, 0, time.UTC)
	registry.now = func() time.Time { return now }
	keys, err := registry.createEnrollmentKeys(1, time.Hour, 2, "test")
	if err != nil {
		t.Fatal(err)
	}
	first, _, err := registry.claimHost(keys[0].Code, "secret-one", "one")
	if err != nil {
		t.Fatal(err)
	}
	// A retry with the same Host Secret is idempotent and does not consume a
	// second use.
	retry, _, err := registry.claimHost(keys[0].Code, "secret-one", "renamed")
	if err != nil || retry != first {
		t.Fatalf("idempotent claim = %s, %v; want %s", retry, err, first)
	}
	second, _, err := registry.claimHost(keys[0].Code, "secret-two", "two")
	if err != nil || second == first {
		t.Fatalf("second key use = %s, %v", second, err)
	}
	if _, _, err := registry.claimHost(keys[0].Code, "secret-three", "three"); err == nil {
		t.Fatal("claim exceeded enrollment key max uses")
	}

	expired, err := registry.createEnrollmentKeys(1, time.Minute, 1, "")
	if err != nil {
		t.Fatal(err)
	}
	now = now.Add(2 * time.Minute)
	if _, _, err := registry.claimHost(expired[0].Code, "secret-expired", "expired"); err == nil {
		t.Fatal("expired enrollment key was accepted")
	}
}

func TestEnrollmentKeyPersistenceStoresOnlyHash(t *testing.T) {
	dataURL := t.TempDir() + "/registry.json"
	registry, err := newRegistry(dataURL)
	if err != nil {
		t.Fatal(err)
	}
	keys, err := registry.createEnrollmentKeys(1, time.Hour, 1, "persisted")
	if err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(dataURL)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data), keys[0].Code) {
		t.Fatal("clear-text enrollment key was persisted")
	}
	reloaded, err := newRegistry(dataURL)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := reloaded.claimHost(keys[0].Code, "persisted-secret", "host"); err != nil {
		t.Fatalf("persisted enrollment key could not be claimed: %v", err)
	}
}
