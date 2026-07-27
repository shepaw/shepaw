package admin

import (
	"encoding/json"
	"net/http"
	"strings"

	"github.com/shepaw/storage-node/internal/noise"
	"github.com/shepaw/storage-node/internal/peer"
	"github.com/shepaw/storage-node/internal/protocol"
	"github.com/shepaw/storage-node/internal/store"
)

// Server exposes privileged admin APIs over the local store (M7 headless).
type Server struct {
	Store           *store.Local
	Auth            AuthConfig
	Device          string
	Hub             *peer.PairingHub
	Peers           *peer.Store
	Identity        *noise.Identity
	Listen          string
	ChannelEndpoint string // optional wss://.../peer/ws for QR + pairing start
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
	api.HandleFunc("/peers/remove", s.handlePeerRemove)
	api.HandleFunc("/gc", s.handleGC)
	api.HandleFunc("/master/migrate", s.handleMasterMigrate)
	api.HandleFunc("/devices/purge", s.handleDevicePurge)
	api.HandleFunc("/devices/wipe-self", s.handleWipeSelf)
	api.HandleFunc("/browse", s.handleBrowse)
	api.HandleFunc("/browse/delete", s.handleBrowseDelete)

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
	data["self_device"] = s.Device
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
	channel := strings.TrimSpace(s.ChannelEndpoint)
	qr := peer.EncodeQR(local, channel, code, s.Identity.Fingerprint(), s.Identity.PublicKey)
	out := map[string]any{
		"code":           code,
		"qr":             qr,
		"local_endpoint": local,
		"fingerprint":    s.Identity.Fingerprint(),
	}
	if channel != "" {
		out["channel_endpoint"] = channel
	}
	writeJSON(w, out)
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

func (s *Server) handlePeerRemove(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	if s.Peers == nil {
		http.Error(w, "peers unavailable", http.StatusServiceUnavailable)
		return
	}
	var body struct {
		Fingerprint string `json:"fingerprint"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.Fingerprint == "" {
		http.Error(w, "fingerprint required", http.StatusBadRequest)
		return
	}
	ok, err := s.Peers.Remove(body.Fingerprint)
	if err != nil {
		writeErr(w, err)
		return
	}
	if !ok {
		writeJSON(w, map[string]any{"ok": false, "error": "not_found"})
		return
	}
	writeJSON(w, map[string]any{"ok": true, "fingerprint": body.Fingerprint})
}

func (s *Server) handleGC(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	stagingRemoved, err := s.Store.GcStaging(0)
	if err != nil {
		writeErr(w, err)
		return
	}
	recycleBytes, err := s.Store.GcRecycle(0)
	if err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, map[string]any{
		"ok":              true,
		"staging_removed": stagingRemoved,
		"recycle_bytes":   recycleBytes,
	})
}

func (s *Server) handleMasterMigrate(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	data, err := s.Store.Handle(protocol.Frame{Op: "master.migrate"}, s.Device, protocol.TrustOwner, true)
	if err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, data)
}

func (s *Server) handleDevicePurge(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	var body struct {
		DeviceID string `json:"device_id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.DeviceID == "" {
		http.Error(w, "device_id required", http.StatusBadRequest)
		return
	}
	freed, err := s.Store.PurgeDevice(body.DeviceID, s.Device)
	if err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, map[string]any{
		"ok":           true,
		"device_id":    body.DeviceID,
		"purged_bytes": freed,
	})
}

func (s *Server) handleWipeSelf(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	var body struct {
		Confirm string `json:"confirm"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, "bad json", http.StatusBadRequest)
		return
	}
	if body.Confirm != "DELETE" {
		http.Error(w, `confirm must be "DELETE"`, http.StatusBadRequest)
		return
	}
	freed, err := s.Store.WipeSelf(s.Device)
	if err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, map[string]any{
		"ok":          true,
		"device_id":   s.Device,
		"freed_bytes": freed,
	})
}

func (s *Server) handleBrowse(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "GET only", http.StatusMethodNotAllowed)
		return
	}
	device := r.URL.Query().Get("device")
	if device == "" {
		device = s.Device
	}
	space := r.URL.Query().Get("space")
	if space == "" {
		space = "files"
	}
	path := r.URL.Query().Get("path")
	data, err := s.Store.AdminList(device, space, path)
	if err != nil {
		writeErr(w, err)
		return
	}
	data["device"] = device
	data["space"] = space
	data["path"] = path
	writeJSON(w, data)
}

func (s *Server) handleBrowseDelete(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	var body struct {
		Device string `json:"device"`
		Space  string `json:"space"`
		Path   string `json:"path"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, "bad json", http.StatusBadRequest)
		return
	}
	if body.Device == "" {
		body.Device = s.Device
	}
	if body.Space == "" || body.Path == "" {
		http.Error(w, "space and path required", http.StatusBadRequest)
		return
	}
	data, err := s.Store.AdminDelete(body.Device, body.Space, body.Path)
	if err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, data)
}

func advertiseLocalWS(listen string) string {
	return peer.AdvertiseLocalWS(listen)
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
