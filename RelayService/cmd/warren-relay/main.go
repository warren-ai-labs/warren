package main

import (
	"log"
	"log/slog"
	"net/http"
	"os"
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
	server, err := controlplane.NewServer(controlplane.Config{
		PublicURL:        env("WARREN_RELAY_PUBLIC_URL", "http://127.0.0.1:8080"),
		AdminToken:       os.Getenv("WARREN_RELAY_ADMIN_TOKEN"),
		SigningKey:       []byte(os.Getenv("WARREN_RELAY_SIGNING_KEY")),
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
