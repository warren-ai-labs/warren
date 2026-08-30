package relay

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestRouteClientConfiguresAndDisablesRoute(t *testing.T) {
	const hostID = "00000000-0000-4000-8000-000000000001"
	var requests []string
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.Header.Get("Authorization") != "Bearer host-secret" {
			t.Fatalf("authorization = %q", request.Header.Get("Authorization"))
		}
		requests = append(requests, request.Method+" "+request.URL.Path)
		if request.Method == http.MethodDelete {
			writer.WriteHeader(http.StatusNoContent)
			return
		}
		if request.Method == http.MethodPost {
			var body map[string]any
			if err := json.NewDecoder(request.Body).Decode(&body); err != nil {
				t.Fatal(err)
			}
			if body["auth_mode"] != "public" || body["enabled"] != true {
				t.Fatalf("route body = %#v", body)
			}
		}
		_, _ = io.WriteString(writer, `{"route_id":"route-1","public_hostname":"public.example.com","host_id":"`+hostID+`","generation":2,"path_prefix":"/","auth_mode":"public","enabled":true}`)
	}))
	defer server.Close()
	client, err := NewRouteClient(server.URL, hostID, "host-secret")
	if err != nil {
		t.Fatal(err)
	}
	route, err := client.Configure(context.Background(), Route{AuthMode: "public", Enabled: true})
	if err != nil || route.ID != "route-1" {
		t.Fatalf("configure route = %#v, %v", route, err)
	}
	if err := client.Disable(context.Background()); err != nil {
		t.Fatal(err)
	}
	if got := strings.Join(requests, ","); got != "POST /v1/hosts/"+hostID+"/route,DELETE /v1/hosts/"+hostID+"/route" {
		t.Fatalf("requests = %q", got)
	}
}

func TestRoutePublicURL(t *testing.T) {
	for _, test := range []struct {
		name  string
		route Route
		base  string
		want  string
	}{
		{name: "dns", route: Route{PublicHostname: "route.tunnel.example", PathPrefix: "/"}, base: "https://relay.example", want: "https://route.tunnel.example/"},
		{name: "ip path", route: Route{PublicHostname: "127.0.0.1", PathPrefix: "/t/route"}, base: "http://127.0.0.1:8080", want: "http://127.0.0.1:8080/t/route"},
	} {
		t.Run(test.name, func(t *testing.T) {
			got, err := test.route.PublicURL(test.base)
			if err != nil || got != test.want {
				t.Fatalf("PublicURL = %q, %v; want %q", got, err, test.want)
			}
		})
	}
}
