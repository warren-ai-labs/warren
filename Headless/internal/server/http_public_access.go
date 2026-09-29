package server

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/relay"
)

func (s *HTTPServer) handlePublicAccess(writer http.ResponseWriter, request *http.Request) {
	if !s.authorized(strings.TrimPrefix(request.Header.Get("Authorization"), "Bearer ")) {
		http.Error(writer, "unauthorized", http.StatusUnauthorized)
		return
	}
	s.writePublicAccessStatus(writer, http.StatusOK, s.publicAccessStatus())
}

func (s *HTTPServer) handlePublicAccessEnable(writer http.ResponseWriter, request *http.Request) {
	if !s.authorized(strings.TrimPrefix(request.Header.Get("Authorization"), "Bearer ")) {
		http.Error(writer, "unauthorized", http.StatusUnauthorized)
		return
	}
	var body api.PublicAccessEnableRequest
	decoder := json.NewDecoder(http.MaxBytesReader(writer, request.Body, 16*1024))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&body); err != nil && !errors.Is(err, io.EOF) {
		s.writePublicAccessError(writer, http.StatusBadRequest, errors.New("invalid public access request"))
		return
	}
	status, err := s.publicAccess.Enable(request.Context(), body)
	if err != nil {
		s.writePublicAccessError(writer, publicAccessHTTPStatus(err), err)
		return
	}
	s.writePublicAccessStatus(writer, http.StatusOK, status)
}

// handlePublicAccessTest validates the Relay route configuration without
// changing the user's enabled intent.
func (s *HTTPServer) handlePublicAccessTest(writer http.ResponseWriter, request *http.Request) {
	if !s.authorized(strings.TrimPrefix(request.Header.Get("Authorization"), "Bearer ")) {
		http.Error(writer, "unauthorized", http.StatusUnauthorized)
		return
	}
	var body api.PublicAccessTestRequest
	decoder := json.NewDecoder(http.MaxBytesReader(writer, request.Body, 16*1024))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&body); err != nil && !errors.Is(err, io.EOF) {
		s.writePublicAccessError(writer, http.StatusBadRequest, errors.New("invalid public access test request"))
		return
	}
	status, err := s.publicAccess.Test(request.Context(), body)
	if err != nil {
		s.writePublicAccessError(writer, publicAccessHTTPStatus(err), err)
		return
	}
	s.writePublicAccessStatus(writer, http.StatusOK, status)
}

func (s *HTTPServer) handlePublicAccessDisable(writer http.ResponseWriter, request *http.Request) {
	if !s.authorized(strings.TrimPrefix(request.Header.Get("Authorization"), "Bearer ")) {
		http.Error(writer, "unauthorized", http.StatusUnauthorized)
		return
	}
	status, err := s.publicAccess.Disable(request.Context())
	if err != nil {
		s.writePublicAccessError(writer, publicAccessHTTPStatus(err), err)
		return
	}
	s.writePublicAccessStatus(writer, http.StatusOK, status)
}

// handlePublicAccessReset disables the Relay route and clears Warren's local
// route metadata. The Relay Host record remains enrolled for later use.
func (s *HTTPServer) handlePublicAccessReset(writer http.ResponseWriter, request *http.Request) {
	if !s.authorized(strings.TrimPrefix(request.Header.Get("Authorization"), "Bearer ")) {
		http.Error(writer, "unauthorized", http.StatusUnauthorized)
		return
	}
	status, err := s.publicAccess.Reset(request.Context())
	if err != nil {
		s.writePublicAccessError(writer, publicAccessHTTPStatus(err), err)
		return
	}
	s.writePublicAccessStatus(writer, http.StatusOK, status)
}

func (s *HTTPServer) handlePublicAccessRestart(writer http.ResponseWriter, request *http.Request) {
	if !s.authorized(strings.TrimPrefix(request.Header.Get("Authorization"), "Bearer ")) {
		http.Error(writer, "unauthorized", http.StatusUnauthorized)
		return
	}
	status, err := s.publicAccess.Restart(request.Context())
	if err != nil {
		s.writePublicAccessError(writer, publicAccessHTTPStatus(err), err)
		return
	}
	s.writePublicAccessStatus(writer, http.StatusOK, status)
}

// publicAccessRPC exposes the same Relay-owned route lifecycle to clients
// connected through the Relay control WebSocket. The daemon performs route
// mutations with its locally held Host Secret; neither that secret nor the
// Relay route capability is placed on the control stream.
func (s *HTTPServer) publicAccessRPC(ctx context.Context, action, publicHostname, pathPrefix string) (api.PublicAccessStatus, error) {
	var publicHostnameValue, pathPrefixValue *string
	if strings.TrimSpace(publicHostname) != "" {
		value := publicHostname
		publicHostnameValue = &value
	}
	if strings.TrimSpace(pathPrefix) != "" {
		value := pathPrefix
		pathPrefixValue = &value
	}
	switch action {
	case "status":
		return s.publicAccess.Status(ctx), nil
	case "enable":
		return s.publicAccess.Enable(ctx, api.PublicAccessEnableRequest{PublicHostname: publicHostnameValue, PathPrefix: pathPrefixValue})
	case "test":
		return s.publicAccess.Test(ctx, api.PublicAccessTestRequest{PublicHostname: publicHostnameValue, PathPrefix: pathPrefixValue})
	case "disable":
		return s.publicAccess.Disable(ctx)
	case "reset":
		return s.publicAccess.Reset(ctx)
	case "restart":
		return s.publicAccess.Restart(ctx)
	default:
		return api.PublicAccessStatus{}, fmt.Errorf("unknown public access action: %s", action)
	}
}

func (s *HTTPServer) publicAccessStatus() api.PublicAccessStatus {
	return s.publicAccess.Status(context.Background())
}

func (s *HTTPServer) routeClient() (*relay.RouteClient, error) {
	if s.RelayRouteClient == nil {
		return nil, errors.New("Relay route is not configured")
	}
	return s.RelayRouteClient()
}

func publicAccessHTTPStatus(err error) int {
	if err == nil {
		return http.StatusOK
	}
	message := strings.ToLower(err.Error())
	if strings.Contains(message, "not configured") || strings.Contains(message, "unavailable") {
		return http.StatusServiceUnavailable
	}
	if strings.Contains(message, "settings") || strings.Contains(message, "state") {
		return http.StatusInternalServerError
	}
	return http.StatusBadGateway
}

func (s *HTTPServer) writePublicAccessStatus(writer http.ResponseWriter, code int, status api.PublicAccessStatus) {
	writer.Header().Set("Content-Type", "application/json")
	writer.WriteHeader(code)
	_ = json.NewEncoder(writer).Encode(status)
}

func (s *HTTPServer) writePublicAccessError(writer http.ResponseWriter, code int, err error) {
	status := s.publicAccessStatus()
	status.Error = err.Error()
	s.writePublicAccessStatus(writer, code, status)
}
