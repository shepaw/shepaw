package admin_test

import (
	"net/http"
	"testing"

	"github.com/shepaw/storage-node/internal/admin"
)

func TestAuthorizeLoopbackWithoutToken(t *testing.T) {
	cfg := admin.AuthConfig{}
	req, _ := http.NewRequest(http.MethodGet, "/admin", nil)
	req.RemoteAddr = "127.0.0.1:12345"
	if !cfg.Authorize(req) {
		t.Fatal("loopback should be allowed without token")
	}
	req.RemoteAddr = "8.8.8.8:12345"
	if cfg.Authorize(req) {
		t.Fatal("remote should be denied without token")
	}
}

func TestAuthorizeBearer(t *testing.T) {
	cfg := admin.AuthConfig{Token: "abc"}
	req, _ := http.NewRequest(http.MethodGet, "/admin", nil)
	req.RemoteAddr = "8.8.8.8:1"
	req.Header.Set("Authorization", "Bearer abc")
	if !cfg.Authorize(req) {
		t.Fatal("bearer should match")
	}
	req.Header.Set("Authorization", "Bearer wrong")
	if cfg.Authorize(req) {
		t.Fatal("wrong bearer must fail")
	}
}
