package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func serve(t *testing.T, method, path string) *httptest.ResponseRecorder {
	t.Helper()
	handler := NewHandler(BuildInfo{Version: "1.2.3", Commit: "abc123"})
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, httptest.NewRequest(method, path, nil))
	return recorder
}

func TestHealthz(t *testing.T) {
	res := serve(t, http.MethodGet, "/healthz")
	if res.Code != http.StatusOK || res.Body.String() != "ok\n" {
		t.Fatalf("got %d %q, want 200 \"ok\\n\"", res.Code, res.Body.String())
	}
}

func TestVersionReturnsTheInjectedBuildInfo(t *testing.T) {
	res := serve(t, http.MethodGet, "/version")
	if res.Code != http.StatusOK {
		t.Fatalf("got status %d, want 200", res.Code)
	}
	var info BuildInfo
	if err := json.NewDecoder(res.Body).Decode(&info); err != nil {
		t.Fatal(err)
	}
	if info != (BuildInfo{Version: "1.2.3", Commit: "abc123"}) {
		t.Fatalf("got %+v", info)
	}
}

func TestOtherMethodsAreRejected(t *testing.T) {
	if res := serve(t, http.MethodPost, "/version"); res.Code != http.StatusMethodNotAllowed {
		t.Fatalf("POST /version: got %d, want 405", res.Code)
	}
}

func TestSecurityHeadersAreOnEveryResponse(t *testing.T) {
	want := map[string]string{
		"Content-Security-Policy": "default-src 'none'; frame-ancestors 'none'",
		"X-Content-Type-Options":  "nosniff",
		"Referrer-Policy":         "no-referrer",
		"Cache-Control":           "no-store",
	}
	// Including errors: a 404 must not be a way around the headers
	for _, path := range []string{"/healthz", "/version", "/does-not-exist"} {
		res := serve(t, http.MethodGet, path)
		for name, value := range want {
			if got := res.Header().Get(name); got != value {
				t.Errorf("%s: %s = %q, want %q", path, name, got, value)
			}
		}
	}
}
