package admin

import (
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"strings"

	"github.com/shepaw/storage-node/internal/noise"
	"github.com/shepaw/storage-node/internal/peer"
	"github.com/shepaw/storage-node/internal/protocol"
	"github.com/shepaw/storage-node/internal/store"
)

// Server exposes privileged admin APIs over the local store (M7 headless).
type Server struct {
	Store    *store.Local
	Auth     AuthConfig
	Device   string
	Hub      *peer.PairingHub
	Peers    *peer.Store
	Identity *noise.Identity
	Listen   string
}

// Mount registers /admin/ (UI) and /admin/api/* on mux.
func (s *Server) Mount(mux *http.ServeMux) {
	api := http.NewServeMux()
	api.HandleFunc("/health", s.handleHealth)
	api.HandleFunc("/stats", s.handleStats)
	api.HandleFunc("/recycle", s.handleRecycle)
	api.HandleFunc("/recycle/empty", s.handleRecycleEmpty)
	api.HandleFunc("/recycle/restore", s.handleRecycleRestore)
	api.HandleFunc("/import/pending", s.handleImportPending)
	api.HandleFunc("/import/grant", s.handleImportGrant)
	api.HandleFunc("/import/reject", s.handleImportReject)
	api.HandleFunc("/import/grants", s.handleImportGrants)
	api.HandleFunc("/pairing/start", s.handlePairingStart)
	api.HandleFunc("/pairing/pending", s.handlePairingPending)
	api.HandleFunc("/pairing/decide", s.handlePairingDecide)
	api.HandleFunc("/peers", s.handlePeers)

	mux.Handle("/admin/api/", RequireAuth(s.Auth, http.StripPrefix("/admin/api", api)))
	mux.Handle("/admin", RequireAuth(s.Auth, http.HandlerFunc(s.handleUI)))
	mux.Handle("/admin/", RequireAuth(s.Auth, http.HandlerFunc(s.handleUI)))
}

func (s *Server) handleHealth(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, map[string]any{
		"ok":       true,
		"device":   s.Device,
		"protocol": protocol.ProtocolVersion,
		"admin":    true,
	})
}

func (s *Server) handleStats(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "GET only", http.StatusMethodNotAllowed)
		return
	}
	data, err := s.Store.Handle(protocol.Frame{Op: "stats"}, s.Device, protocol.TrustOwner, true)
	if err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, data)
}

func (s *Server) handleRecycle(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "GET only", http.StatusMethodNotAllowed)
		return
	}
	data, err := s.Store.Handle(protocol.Frame{Op: "recycle.list"}, s.Device, protocol.TrustOwner, true)
	if err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, data)
}

func (s *Server) handleRecycleEmpty(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	data, err := s.Store.Handle(protocol.Frame{Op: "recycle.empty"}, s.Device, protocol.TrustOwner, true)
	if err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, data)
}

func (s *Server) handleRecycleRestore(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	var body struct {
		RecyclePath string `json:"recycle_path"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.RecyclePath == "" {
		http.Error(w, "recycle_path required", http.StatusBadRequest)
		return
	}
	data, err := s.Store.Handle(protocol.Frame{
		Op: "recycle.restore",
		Payload: map[string]any{
			"recycle_path": body.RecyclePath,
		},
	}, s.Device, protocol.TrustOwner, true)
	if err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, data)
}

func (s *Server) handleImportPending(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "GET only", http.StatusMethodNotAllowed)
		return
	}
	data, err := s.Store.Handle(protocol.Frame{Op: "import.pending"}, s.Device, protocol.TrustOwner, true)
	if err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, data)
}

func (s *Server) handleImportGrant(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	var body struct {
		RequestID string `json:"request_id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.RequestID == "" {
		http.Error(w, "request_id required", http.StatusBadRequest)
		return
	}
	data, err := s.Store.Handle(protocol.Frame{
		Op:      "import.grant",
		Payload: map[string]any{"request_id": body.RequestID},
	}, s.Device, protocol.TrustOwner, true)
	if err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, data)
}

func (s *Server) handleImportReject(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	var body struct {
		RequestID string `json:"request_id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.RequestID == "" {
		http.Error(w, "request_id required", http.StatusBadRequest)
		return
	}
	data, err := s.Store.Handle(protocol.Frame{
		Op:      "import.reject",
		Payload: map[string]any{"request_id": body.RequestID},
	}, s.Device, protocol.TrustOwner, true)
	if err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, data)
}

func (s *Server) handleImportGrants(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "GET only", http.StatusMethodNotAllowed)
		return
	}
	role := r.URL.Query().Get("role")
	if role == "" {
		role = "issued"
	}
	data, err := s.Store.Handle(protocol.Frame{
		Op:      "import.grants",
		Payload: map[string]any{"role": role},
	}, s.Device, protocol.TrustOwner, true)
	if err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, data)
}

func (s *Server) handlePairingStart(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	if s.Hub == nil || s.Identity == nil {
		http.Error(w, "pairing unavailable", http.StatusServiceUnavailable)
		return
	}
	_, code, err := s.Hub.Start()
	if err != nil {
		writeErr(w, err)
		return
	}
	local := advertiseLocalWS(s.Listen)
	qr := peer.EncodeQR(local, code, s.Identity.Fingerprint(), s.Identity.PublicKey)
	writeJSON(w, map[string]any{
		"code":          code,
		"qr":            qr,
		"local_endpoint": local,
		"fingerprint":   s.Identity.Fingerprint(),
	})
}

func (s *Server) handlePairingPending(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "GET only", http.StatusMethodNotAllowed)
		return
	}
	if s.Hub == nil {
		writeJSON(w, map[string]any{"pending": nil})
		return
	}
	writeJSON(w, map[string]any{"pending": s.Hub.Pending()})
}

func (s *Server) handlePairingDecide(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	var body struct {
		Accept bool `json:"accept"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, "bad json", http.StatusBadRequest)
		return
	}
	if s.Hub == nil {
		http.Error(w, "pairing unavailable", http.StatusServiceUnavailable)
		return
	}
	if err := s.Hub.Decide(body.Accept); err != nil {
		http.Error(w, err.Error(), http.StatusConflict)
		return
	}
	writeJSON(w, map[string]any{"ok": true, "accept": body.Accept})
}

func (s *Server) handlePeers(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "GET only", http.StatusMethodNotAllowed)
		return
	}
	if s.Peers == nil {
		writeJSON(w, map[string]any{"peers": []any{}})
		return
	}
	peers, err := s.Peers.List()
	if err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, map[string]any{"peers": peers})
}

func advertiseLocalWS(listen string) string {
	host, port, err := net.SplitHostPort(listen)
	if err != nil {
		return "ws://127.0.0.1:8787/peer/ws"
	}
	if host == "" || host == "0.0.0.0" || host == "::" {
		host = firstNonLoopbackIPv4()
		if host == "" {
			host = "127.0.0.1"
		}
	}
	if strings.Contains(host, ":") {
		host = "[" + host + "]"
	}
	return fmt.Sprintf("ws://%s:%s/peer/ws", host, port)
}

func firstNonLoopbackIPv4() string {
	ifaces, err := net.Interfaces()
	if err != nil {
		return ""
	}
	for _, iface := range ifaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		addrs, _ := iface.Addrs()
		for _, a := range addrs {
			var ip net.IP
			switch v := a.(type) {
			case *net.IPNet:
				ip = v.IP
			case *net.IPAddr:
				ip = v.IP
			}
			if ip == nil || ip.IsLoopback() {
				continue
			}
			ip = ip.To4()
			if ip != nil {
				return ip.String()
			}
		}
	}
	return ""
}

func (s *Server) handleUI(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/admin" && r.URL.Path != "/admin/" {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_, _ = w.Write([]byte(uiHTML))
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}

func writeErr(w http.ResponseWriter, err error) {
	code := "internal"
	msg := err.Error()
	if oe, ok := err.(*store.OpError); ok {
		code = oe.Code
		msg = oe.Msg
	}
	w.WriteHeader(http.StatusBadRequest)
	writeJSON(w, map[string]any{"error": code, "message": msg})
}
