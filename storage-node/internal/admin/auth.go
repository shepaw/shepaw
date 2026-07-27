package admin

import (
	"crypto/subtle"
	"net"
	"net/http"
	"strings"
)

// AuthConfig controls admin surface access.
// If Token is non-empty, requests must present Bearer/X-Admin-Token matching it.
// If Token is empty, only loopback clients are allowed (dev convenience).
type AuthConfig struct {
	Token string
}

func (c AuthConfig) Authorize(r *http.Request) bool {
	if c.Token != "" {
		got := bearerToken(r)
		if got == "" {
			got = r.Header.Get("X-Admin-Token")
		}
		if got == "" {
			got = r.URL.Query().Get("token")
		}
		return subtle.ConstantTimeCompare([]byte(got), []byte(c.Token)) == 1
	}
	return isLoopback(r.RemoteAddr)
}

func bearerToken(r *http.Request) string {
	h := r.Header.Get("Authorization")
	if len(h) < 8 {
		return ""
	}
	if !strings.EqualFold(h[:7], "bearer ") {
		return ""
	}
	return strings.TrimSpace(h[7:])
}

func isLoopback(remoteAddr string) bool {
	host, _, err := net.SplitHostPort(remoteAddr)
	if err != nil {
		host = remoteAddr
	}
	ip := net.ParseIP(host)
	if ip == nil {
		return host == "localhost"
	}
	return ip.IsLoopback()
}

func RequireAuth(cfg AuthConfig, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !cfg.Authorize(r) {
			w.Header().Set("WWW-Authenticate", `Bearer realm="shepaw-admin"`)
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		next.ServeHTTP(w, r)
	})
}
