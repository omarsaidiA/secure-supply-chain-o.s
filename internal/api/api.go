// Package api serves the health and build information endpoints.
package api

import (
	"encoding/json"
	"net/http"
)

// BuildInfo identifies the exact source the binary was built from. The values are injected
// at build time (-ldflags) and can be compared with the signed provenance of the image.
type BuildInfo struct {
	Version string `json:"version"`
	Commit  string `json:"commit"`
}

// NewHandler returns the routes, all behind the security headers. Method-qualified patterns
// make the router answer 405 to any other method.
func NewHandler(info BuildInfo) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = w.Write([]byte("ok\n"))
	})
	mux.HandleFunc("GET /version", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(info)
	})
	return securityHeaders(mux)
}

func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("Content-Security-Policy", "default-src 'none'; frame-ancestors 'none'")
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("Referrer-Policy", "no-referrer")
		h.Set("Cache-Control", "no-store")
		next.ServeHTTP(w, r)
	})
}
