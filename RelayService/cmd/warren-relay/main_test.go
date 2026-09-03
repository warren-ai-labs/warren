package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestAPNsPrivateKeyFromEnvironmentReadsFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "AuthKey.p8")
	want := []byte("-----BEGIN PRIVATE KEY-----\nkey\n-----END PRIVATE KEY-----\n")
	if err := os.WriteFile(path, want, 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("WARREN_RELAY_APNS_PRIVATE_KEY", "")
	t.Setenv("WARREN_RELAY_APNS_PRIVATE_KEY_FILE", path)
	got, err := apnsPrivateKeyFromEnvironment()
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != string(want) {
		t.Fatalf("private key = %q, want %q", got, want)
	}
}

func TestAPNsPrivateKeyEnvironmentRejectsAmbiguousSources(t *testing.T) {
	t.Setenv("WARREN_RELAY_APNS_PRIVATE_KEY", "inline")
	t.Setenv("WARREN_RELAY_APNS_PRIVATE_KEY_FILE", "/tmp/key.p8")
	if _, err := apnsPrivateKeyFromEnvironment(); err == nil {
		t.Fatal("accepted both inline and file APNs private keys")
	}
}

func TestBoolEnv(t *testing.T) {
	t.Setenv("WARREN_RELAY_APNS_PRODUCTION", "true")
	got, err := boolEnv("WARREN_RELAY_APNS_PRODUCTION", false)
	if err != nil || !got {
		t.Fatalf("boolEnv(true) = %v, %v", got, err)
	}
	t.Setenv("WARREN_RELAY_APNS_PRODUCTION", "invalid")
	if _, err := boolEnv("WARREN_RELAY_APNS_PRODUCTION", false); err == nil {
		t.Fatal("accepted invalid boolean")
	}
}
