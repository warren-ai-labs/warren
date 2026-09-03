package main

import (
	"errors"
	"fmt"
	"log"
	"log/slog"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/abcdlsj/warren/RelayService/internal/controlplane"
)

func main() {
	address := env("WARREN_RELAY_LISTEN", ":8080")
	allowedOrigin := strings.TrimSpace(os.Getenv("WARREN_RELAY_ALLOWED_ORIGIN"))
	if allowedOrigin == "" {
		log.Fatal("WARREN_RELAY_ALLOWED_ORIGIN is required")
	}
	apnsPrivateKey, err := apnsPrivateKeyFromEnvironment()
	if err != nil {
		log.Fatal(err)
	}
	apnsProduction, err := boolEnv("WARREN_RELAY_APNS_PRODUCTION", false)
	if err != nil {
		log.Fatal(err)
	}
	server, err := controlplane.NewServer(controlplane.Config{
		PublicURL:        env("WARREN_RELAY_PUBLIC_URL", "http://127.0.0.1:8080"),
		AdminToken:       os.Getenv("WARREN_RELAY_ADMIN_TOKEN"),
		SigningKey:       []byte(os.Getenv("WARREN_RELAY_SIGNING_KEY")),
		APNsKeyID:        os.Getenv("WARREN_RELAY_APNS_KEY_ID"),
		APNsTeamID:       os.Getenv("WARREN_RELAY_APNS_TEAM_ID"),
		APNsBundleID:     os.Getenv("WARREN_RELAY_APNS_BUNDLE_ID"),
		APNsPrivateKey:   apnsPrivateKey,
		APNsProduction:   apnsProduction,
		APNsEndpoint:     os.Getenv("WARREN_RELAY_APNS_ENDPOINT"),
		DataURL:          env("WARREN_RELAY_DATA", "./data/registry.json"),
		AllowedOrigin:    allowedOrigin,
		TunnelBaseDomain: env("WARREN_RELAY_TUNNEL_BASE_DOMAIN", "tunnel.local"),
		PairingTTL:       durationEnv("WARREN_RELAY_PAIRING_TTL", 7*24*time.Hour),
		PairingTicketTTL: durationEnv("WARREN_RELAY_PAIRING_TICKET_TTL", 7*24*time.Hour),
		AccessTTL:        durationEnv("WARREN_RELAY_ACCESS_TTL", 15*time.Minute),
		Logger:           slog.Default(),
	})
	if err != nil {
		log.Fatal(err)
	}
	if env("WARREN_RELAY_PRINT_SETUP_LINK", "1") != "0" {
		setupLink, setupErr := server.NewSetupLink(env("WARREN_RELAY_SETUP_NAME", "Warren Host"))
		if setupErr != nil {
			log.Fatal("create Relay setup link: ", setupErr)
		}
		if setupLink != "" {
			slog.Info("Warren Relay setup link", "setup_link", setupLink)
		}
	}
	slog.Info("Warren Relay listening", "address", address)
	httpServer := &http.Server{
		Addr: address, Handler: server,
		ReadHeaderTimeout: 5 * time.Second,
		IdleTimeout:       120 * time.Second,
		MaxHeaderBytes:    32 * 1024,
	}
	certFile := strings.TrimSpace(os.Getenv("WARREN_RELAY_TLS_CERT"))
	keyFile := strings.TrimSpace(os.Getenv("WARREN_RELAY_TLS_KEY"))
	if (certFile == "") != (keyFile == "") {
		log.Fatal("WARREN_RELAY_TLS_CERT and WARREN_RELAY_TLS_KEY must be provided together")
	}
	if certFile != "" {
		log.Fatal(httpServer.ListenAndServeTLS(certFile, keyFile))
	}
	log.Fatal(httpServer.ListenAndServe())
}

func env(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}

func durationEnv(name string, fallback time.Duration) time.Duration {
	value := strings.TrimSpace(os.Getenv(name))
	if value == "" {
		return fallback
	}
	duration, err := time.ParseDuration(value)
	if err != nil {
		log.Fatalf("%s must be a valid duration: %v", name, err)
	}
	return duration
}

func boolEnv(name string, fallback bool) (bool, error) {
	value := strings.TrimSpace(os.Getenv(name))
	if value == "" {
		return fallback, nil
	}
	parsed, err := strconv.ParseBool(value)
	if err != nil {
		return false, fmt.Errorf("%s must be a boolean: %w", name, err)
	}
	return parsed, nil
}

func apnsPrivateKeyFromEnvironment() ([]byte, error) {
	inline := os.Getenv("WARREN_RELAY_APNS_PRIVATE_KEY")
	file := strings.TrimSpace(os.Getenv("WARREN_RELAY_APNS_PRIVATE_KEY_FILE"))
	if inline != "" && file != "" {
		return nil, errors.New("WARREN_RELAY_APNS_PRIVATE_KEY and WARREN_RELAY_APNS_PRIVATE_KEY_FILE are mutually exclusive")
	}
	if file != "" {
		key, err := os.ReadFile(file)
		if err != nil {
			return nil, fmt.Errorf("read APNs private key file: %w", err)
		}
		return key, nil
	}
	return []byte(inline), nil
}
