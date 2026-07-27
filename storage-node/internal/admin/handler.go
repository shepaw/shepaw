package admin

import (
	"encoding/json"
	"net/http"

	"github.com/shepaw/storage-node/internal/protocol"
	"github.com/shepaw/storage-node/internal/store"
)

// Server exposes privileged admin APIs over the local store (M7 headless).
type Server struct {
	Store  *store.Local
	Auth   AuthConfig
	Device string
}

// Mount registers /admin/ (UI) and /admin/api/* on mux.
func (s *Server) Mount(mux *http.ServeMux) {
	api := http.NewServeMux()
	api.HandleFunc("/health", s.handleHealth)
	api.HandleFunc("/stats", s.handleStats)
	api.HandleFunc("/recycle", s.handleRecycle)
	api.HandleFunc("/recycle/empty", s.handleRecycleEmpty)
	api.HandleFunc("/recycle/restore", s.handleRecycleRestore)

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
