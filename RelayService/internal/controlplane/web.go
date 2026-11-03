package controlplane

import (
	"encoding/json"
	"fmt"
	"io/fs"
	"mime"
	"net/http"
	"net/url"
	"path"
	"strings"
)

type httpHeadersMessage struct {
	Status    int         `json:"status,omitempty"`
	Method    string      `json:"method,omitempty"`
	Scheme    string      `json:"scheme,omitempty"`
	Authority string      `json:"authority,omitempty"`
	Path      string      `json:"path,omitempty"`
	BodyLimit int64       `json:"body_limit,omitempty"`
	Headers   [][2]string `json:"headers,omitempty"`
	Trailers  [][2]string `json:"trailers,omitempty"`
}

type httpErrorMessage struct {
	Code    string `json:"code"`
	Message string `json:"message,omitempty"`
}

var webStaticResources = map[string]string{
	"apple-touch-icon.png":   "image/png",
	"favicon-16.png":         "image/png",
	"favicon-32.png":         "image/png",
	"icon-192.png":           "image/png",
	"icon-512.png":           "image/png",
	"icon.svg":               "image/svg+xml",
	"preset-antigravity.svg": "image/svg+xml",
	"preset-claude.svg":      "image/svg+xml",
	"preset-codex-white.svg": "image/svg+xml",
	"preset-codex.svg":       "image/svg+xml",
	"preset-opencode.svg":    "image/svg+xml",
	"preset-pi.svg":          "image/svg+xml",
	"preset-qoder.svg":       "image/svg+xml",
	"preset-shell.svg":       "image/svg+xml",
	"preset-trae.svg":        "image/svg+xml",
}

func (server *Server) webPage(response http.ResponseWriter, request *http.Request) {
	data, err := fs.ReadFile(server.web, "index.html")
	if err != nil {
		http.Error(response, "web unavailable", http.StatusInternalServerError)
		return
	}
	hostID, _ := json.Marshal(request.PathValue("hostID"))
	prefix := server.publicPath("/h/" + url.PathEscape(request.PathValue("hostID")))
	page := strings.Replace(string(data), "content=\"__WARREN_RELAY_HOST_ID__\"", fmt.Sprintf("content=%s", string(hostID)), 1)
	page = scopeWebPage(page, prefix)
	response.Header().Set("Cache-Control", "no-store")
	response.Header().Set("Content-Type", "text/html; charset=utf-8")
	_, _ = response.Write([]byte(page))
}

// invitePage serves the same Web client from an opaque invite scope. The
// invite ID is injected into a dedicated meta tag; the client exchanges it
// over the matching scoped endpoint and learns the Host ID only in memory.
func (server *Server) invitePage(response http.ResponseWriter, request *http.Request) {
	inviteID := strings.TrimSpace(request.PathValue("inviteID"))
	if inviteID == "" {
		http.NotFound(response, request)
		return
	}
	data, err := fs.ReadFile(server.web, "index.html")
	if err != nil {
		http.Error(response, "web unavailable", http.StatusInternalServerError)
		return
	}
	encodedID, _ := json.Marshal(inviteID)
	prefix := server.publicPath("/invite/" + url.PathEscape(inviteID))
	page := strings.Replace(string(data), "content=\"__WARREN_RELAY_INVITE_ID__\"", fmt.Sprintf("content=%s", string(encodedID)), 1)
	page = scopeWebPage(page, prefix)
	response.Header().Set("Cache-Control", "no-store")
	response.Header().Set("Content-Type", "text/html; charset=utf-8")
	_, _ = response.Write([]byte(page))
}

func scopeWebPage(page, prefix string) string {
	for _, attribute := range []string{"href", "src", "srcset"} {
		for _, assetPrefix := range []string{"/assets/", "./assets/"} {
			page = strings.ReplaceAll(page, attribute+"=\""+assetPrefix, attribute+"=\""+prefix+"/assets/")
		}
	}
	resources := []string{"manifest.webmanifest"}
	for resource := range webStaticResources {
		resources = append(resources, resource)
	}
	for _, resource := range resources {
		for _, attribute := range []string{"href", "src", "srcset"} {
			for _, resourcePrefix := range []string{"/", "./"} {
				page = strings.ReplaceAll(page, attribute+"=\""+resourcePrefix+resource+"\"", attribute+"=\""+prefix+"/"+resource+"\"")
			}
		}
	}
	return page
}

func (server *Server) hostManifest(response http.ResponseWriter, request *http.Request) {
	server.scopedManifest(response, request, "/h/"+url.PathEscape(request.PathValue("hostID")))
}

func (server *Server) inviteManifest(response http.ResponseWriter, request *http.Request) {
	server.scopedManifest(response, request, "/invite/"+url.PathEscape(request.PathValue("inviteID")))
}

func (server *Server) scopedManifest(response http.ResponseWriter, request *http.Request, scope string) {
	data, err := fs.ReadFile(server.web, "manifest.webmanifest")
	if err != nil {
		http.NotFound(response, request)
		return
	}
	var manifest map[string]any
	if json.Unmarshal(data, &manifest) != nil {
		http.Error(response, "invalid manifest", http.StatusInternalServerError)
		return
	}
	prefix := server.publicPath(scope)
	manifest["start_url"] = prefix + "/"
	manifest["scope"] = prefix + "/"
	manifest["icons"] = []map[string]any{{"src": prefix + "/icon.svg", "sizes": "any", "type": "image/svg+xml", "purpose": "any maskable"}}
	writeJSON(response, http.StatusOK, manifest)
}

func (server *Server) hostServiceWorker(response http.ResponseWriter, request *http.Request) {
	host := url.PathEscape(request.PathValue("hostID"))
	server.scopedServiceWorker(response, request, "/h/"+host, host)
}

func (server *Server) inviteServiceWorker(response http.ResponseWriter, request *http.Request) {
	invite := url.PathEscape(request.PathValue("inviteID"))
	server.scopedServiceWorker(response, request, "/invite/"+invite, invite)
}

func (server *Server) scopedServiceWorker(response http.ResponseWriter, request *http.Request, scope, cacheID string) {
	prefix := server.publicPath(scope)
	shell := []string{prefix + "/", prefix + "/manifest.webmanifest", prefix + "/assets/app.js", prefix + "/assets/app.css"}
	for name := range webStaticResources {
		shell = append(shell, prefix+"/"+name)
	}
	encodedShell, _ := json.Marshal(shell)
	script := fmt.Sprintf(`const CACHE="warren-relay-%s-v1";
const SHELL=%s;
self.addEventListener("install",e=>{e.waitUntil(caches.open(CACHE).then(c=>c.addAll(SHELL)));self.skipWaiting()});
self.addEventListener("activate",e=>{e.waitUntil(caches.keys().then(k=>Promise.all(k.filter(x=>x.startsWith("warren-relay-")&&x!==CACHE).map(x=>caches.delete(x)))));self.clients.claim()});
self.addEventListener("fetch",e=>{const p=new URL(e.request.url).pathname;if(e.request.method!=="GET"||p.includes("/v1/client/connect"))return;e.respondWith(fetch(e.request).catch(()=>caches.match(e.request)))})`, cacheID, encodedShell)
	response.Header().Set("Content-Type", "text/javascript; charset=utf-8")
	response.Header().Set("Service-Worker-Allowed", prefix+"/")
	response.Header().Set("Cache-Control", "no-cache")
	_, _ = response.Write([]byte(script))
}

func (server *Server) webResource(name, contentType string) http.HandlerFunc {
	return func(response http.ResponseWriter, _ *http.Request) {
		data, err := fs.ReadFile(server.web, name)
		if err != nil {
			http.NotFound(response, nil)
			return
		}
		response.Header().Set("Content-Type", contentType)
		response.Header().Set("Cache-Control", "no-cache")
		_, _ = response.Write(data)
	}
}

func (server *Server) asset(response http.ResponseWriter, request *http.Request) {
	server.serveAsset(response, request.PathValue("name"))
}

func (server *Server) serveAsset(response http.ResponseWriter, name string) {
	if strings.Contains(name, "/") || strings.Contains(name, "..") {
		http.NotFound(response, nil)
		return
	}
	data, err := fs.ReadFile(server.web, "assets/"+name)
	if err != nil {
		http.NotFound(response, nil)
		return
	}
	contentType := mime.TypeByExtension(path.Ext(name))
	if contentType == "" {
		contentType = "application/octet-stream"
	}
	response.Header().Set("Content-Type", contentType)
	response.Header().Set("Cache-Control", "no-cache")
	_, _ = response.Write(data)
}
