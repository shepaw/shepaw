package admin_test

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"github.com/shepaw/storage-node/internal/admin"
	"github.com/shepaw/storage-node/internal/peer"
	"github.com/shepaw/storage-node/internal/protocol"
	"github.com/shepaw/storage-node/internal/store"
)

func TestAdminAuthTokenRequired(t *testing.T) {
	root := t.TempDir()
	device := "aaaaaaaaaaaaaaaa"
	s, err := store.Open(root, device)
	if err != nil {
		t.Fatal(err)
	}
	srv := &admin.Server{
		Store:  s,
		Device: device,
		Auth:   admin.AuthConfig{Token: "secret"},
	}
	mux := http.NewServeMux()
	srv.Mount(mux)

	req := httptest.NewRequest(http.MethodGet, "/admin/api/stats", nil)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("want 401, got %d", rec.Code)
	}

	req = httptest.NewRequest(http.MethodGet, "/admin/api/stats", nil)
	req.Header.Set("Authorization", "Bearer secret")
	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("want 200, got %d body=%s", rec.Code, rec.Body.String())
	}
}

func TestAdminRecycleEmpty(t *testing.T) {
	root := t.TempDir()
	device := "aaaaaaaaaaaaaaaa"
	s, err := store.Open(root, device)
	if err != nil {
		t.Fatal(err)
	}
	// seed a file then delete into recycle
	begin, err := s.Handle(protocol.Frame{
		Op: "write.begin",
		Payload: map[string]any{
			"space": "files",
			"path":  "gone.txt",
		},
	}, device, protocol.TrustOwner, true)
	if err != nil {
		t.Fatal(err)
	}
	id := begin["upload_id"].(string)
	_, err = s.Handle(protocol.Frame{
		Op: "write.chunk",
		Payload: map[string]any{
			"upload_id": id,
			"data":      base64.StdEncoding.EncodeToString([]byte("x")),
		},
	}, device, protocol.TrustOwner, true)
	if err != nil {
		t.Fatal(err)
	}
	_, err = s.Handle(protocol.Frame{
		Op:      "commit",
		Payload: map[string]any{"upload_ids": []any{id}},
	}, device, protocol.TrustOwner, true)
	if err != nil {
		t.Fatal(err)
	}
	_, err = s.Handle(protocol.Frame{
		Op:      "delete",
		Payload: map[string]any{"space": "files", "path": "gone.txt"},
	}, device, protocol.TrustOwner, true)
	if err != nil {
		t.Fatal(err)
	}

	srv := &admin.Server{
		Store:  s,
		Device: device,
		Auth:   admin.AuthConfig{Token: "t"},
	}
	mux := http.NewServeMux()
	srv.Mount(mux)

	req := httptest.NewRequest(http.MethodGet, "/admin/api/recycle", nil)
	req.Header.Set("X-Admin-Token", "t")
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("recycle list: %d %s", rec.Code, rec.Body.String())
	}
	var listed map[string]any
	_ = json.Unmarshal(rec.Body.Bytes(), &listed)
	entries, _ := listed["entries"].([]any)
	if len(entries) == 0 {
		t.Fatal("expected recycle entries")
	}

	req = httptest.NewRequest(http.MethodPost, "/admin/api/recycle/empty", bytes.NewReader(nil))
	req.Header.Set("Authorization", "Bearer t")
	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("empty: %d %s", rec.Code, rec.Body.String())
	}

	req = httptest.NewRequest(http.MethodGet, "/admin/api/recycle", nil)
	req.Header.Set("Authorization", "Bearer t")
	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	_ = json.Unmarshal(rec.Body.Bytes(), &listed)
	entries, _ = listed["entries"].([]any)
	if len(entries) != 0 {
		t.Fatalf("want empty recycle, got %v", entries)
	}
}

func TestAdminImportGrant(t *testing.T) {
	root := t.TempDir()
	device := "aaaaaaaaaaaaaaaa"
	newDev := "bbbbbbbbbbbbbbbb"
	oldDev := "cccccccccccccccc"
	s, err := store.Open(root, device)
	if err != nil {
		t.Fatal(err)
	}
	_, err = s.Handle(protocol.Frame{
		Op:      "import.request",
		Payload: map[string]any{"old_device": oldDev},
	}, newDev, protocol.TrustOwner, false)
	if err != nil {
		t.Fatal(err)
	}

	srv := &admin.Server{
		Store:  s,
		Device: device,
		Auth:   admin.AuthConfig{Token: "t"},
	}
	mux := http.NewServeMux()
	srv.Mount(mux)

	req := httptest.NewRequest(http.MethodGet, "/admin/api/import/pending", nil)
	req.Header.Set("Authorization", "Bearer t")
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("pending: %d %s", rec.Code, rec.Body.String())
	}
	var pending map[string]any
	_ = json.Unmarshal(rec.Body.Bytes(), &pending)
	arr := pending["requests"].([]any)
	if len(arr) != 1 {
		t.Fatalf("%v", pending)
	}
	requestID := arr[0].(map[string]any)["request_id"].(string)

	body, _ := json.Marshal(map[string]string{"request_id": requestID})
	req = httptest.NewRequest(http.MethodPost, "/admin/api/import/grant", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer t")
	req.Header.Set("Content-Type", "application/json")
	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("grant: %d %s", rec.Code, rec.Body.String())
	}
	var grantBody map[string]any
	_ = json.Unmarshal(rec.Body.Bytes(), &grantBody)
	if grantBody["pushed"] != false {
		t.Fatalf("offline requester should not be pushed: %v", grantBody)
	}
}

func TestAdminDevicePurge(t *testing.T) {
	root := t.TempDir()
	self := "aaaaaaaaaaaaaaaa"
	other := "bbbbbbbbbbbbbbbb"
	s, err := store.Open(root, self)
	if err != nil {
		t.Fatal(err)
	}
	otherDir := filepath.Join(root, other, "files")
	if err := os.MkdirAll(otherDir, 0o755); err != nil {
		t.Fatal(err)
	}
	_ = os.WriteFile(filepath.Join(otherDir, "x.txt"), []byte("data"), 0o644)

	srv := &admin.Server{
		Store:  s,
		Device: self,
		Auth:   admin.AuthConfig{Token: "t"},
	}
	mux := http.NewServeMux()
	srv.Mount(mux)

	body, _ := json.Marshal(map[string]string{"device_id": other})
	req := httptest.NewRequest(http.MethodPost, "/admin/api/devices/purge", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer t")
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("purge: %d %s", rec.Code, rec.Body.String())
	}
	var out map[string]any
	_ = json.Unmarshal(rec.Body.Bytes(), &out)
	if out["ok"] != true {
		t.Fatalf("%v", out)
	}
	if _, err := os.Stat(filepath.Join(root, other)); !os.IsNotExist(err) {
		t.Fatal("dir should be gone")
	}

	// cannot purge self
	body, _ = json.Marshal(map[string]string{"device_id": self})
	req = httptest.NewRequest(http.MethodPost, "/admin/api/devices/purge", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer t")
	req.Header.Set("Content-Type", "application/json")
	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code == http.StatusOK {
		t.Fatal("self purge should fail")
	}
}

func TestAdminBrowseAPI(t *testing.T) {
	root := t.TempDir()
	self := "aaaaaaaaaaaaaaaa"
	other := "bbbbbbbbbbbbbbbb"
	s, err := store.Open(root, self)
	if err != nil {
		t.Fatal(err)
	}
	dir := filepath.Join(root, other, "files")
	_ = os.MkdirAll(dir, 0o755)
	_ = os.WriteFile(filepath.Join(dir, "a.txt"), []byte("hi"), 0o644)

	srv := &admin.Server{
		Store:  s,
		Device: self,
		Auth:   admin.AuthConfig{Token: "t"},
	}
	mux := http.NewServeMux()
	srv.Mount(mux)

	req := httptest.NewRequest(http.MethodGet, "/admin/api/browse?device="+other+"&space=files", nil)
	req.Header.Set("Authorization", "Bearer t")
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("browse: %d %s", rec.Code, rec.Body.String())
	}
	var listed map[string]any
	_ = json.Unmarshal(rec.Body.Bytes(), &listed)
	entries, _ := listed["entries"].([]any)
	if len(entries) != 1 {
		t.Fatalf("%v", listed)
	}

	body, _ := json.Marshal(map[string]string{
		"device": other, "space": "files", "path": "a.txt",
	})
	req = httptest.NewRequest(http.MethodPost, "/admin/api/browse/delete", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer t")
	req.Header.Set("Content-Type", "application/json")
	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("delete: %d %s", rec.Code, rec.Body.String())
	}
}

func TestAdminWipeSelfAPI(t *testing.T) {
	root := t.TempDir()
	self := "aaaaaaaaaaaaaaaa"
	s, err := store.Open(root, self)
	if err != nil {
		t.Fatal(err)
	}
	dir := filepath.Join(root, self, "files")
	_ = os.MkdirAll(dir, 0o755)
	_ = os.WriteFile(filepath.Join(dir, "a.txt"), []byte("x"), 0o644)

	srv := &admin.Server{
		Store:  s,
		Device: self,
		Auth:   admin.AuthConfig{Token: "t"},
	}
	mux := http.NewServeMux()
	srv.Mount(mux)

	// missing confirm
	body, _ := json.Marshal(map[string]string{"confirm": "nope"})
	req := httptest.NewRequest(http.MethodPost, "/admin/api/devices/wipe-self", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer t")
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code == http.StatusOK {
		t.Fatal("expected reject without DELETE")
	}

	body, _ = json.Marshal(map[string]string{"confirm": "DELETE"})
	req = httptest.NewRequest(http.MethodPost, "/admin/api/devices/wipe-self", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer t")
	req.Header.Set("Content-Type", "application/json")
	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("wipe: %d %s", rec.Code, rec.Body.String())
	}
	if _, err := os.Stat(filepath.Join(dir, "a.txt")); !os.IsNotExist(err) {
		t.Fatal("file should be wiped")
	}
}

func TestAdminPeerRemoveAndGC(t *testing.T) {
	root := t.TempDir()
	self := "aaaaaaaaaaaaaaaa"
	s, err := store.Open(root, self)
	if err != nil {
		t.Fatal(err)
	}
	peers := peer.NewStore(root)
	_ = peers.Upsert(peer.Peer{
		Fingerprint: "bbbbbbbbbbbbbbbb",
		PublicKeyB64: "x",
		DeviceName:  "phone",
		PeerID:      "peer-1",
		TrustLevel:  protocol.TrustOwner,
		PairedAtMs:  peer.NowMs(),
	})

	srv := &admin.Server{
		Store:  s,
		Device: self,
		Auth:   admin.AuthConfig{Token: "t"},
		Peers:  peers,
	}
	mux := http.NewServeMux()
	srv.Mount(mux)

	body, _ := json.Marshal(map[string]string{"fingerprint": "bbbbbbbbbbbbbbbb"})
	req := httptest.NewRequest(http.MethodPost, "/admin/api/peers/remove", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer t")
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("remove: %d %s", rec.Code, rec.Body.String())
	}
	list, _ := peers.List()
	if len(list) != 0 {
		t.Fatalf("peers=%v", list)
	}

	req = httptest.NewRequest(http.MethodPost, "/admin/api/gc", nil)
	req.Header.Set("Authorization", "Bearer t")
	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("gc: %d %s", rec.Code, rec.Body.String())
	}
}

func TestAdminUI(t *testing.T) {
	root := t.TempDir()
	device := "aaaaaaaaaaaaaaaa"
	s, err := store.Open(root, device)
	if err != nil {
		t.Fatal(err)
	}
	srv := &admin.Server{
		Store:  s,
		Device: device,
		Auth:   admin.AuthConfig{Token: "ui"},
	}
	mux := http.NewServeMux()
	srv.Mount(mux)
	req := httptest.NewRequest(http.MethodGet, "/admin/", nil)
	req.Header.Set("Authorization", "Bearer ui")
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("ui: %d", rec.Code)
	}
	if ct := rec.Header().Get("Content-Type"); ct == "" || rec.Body.Len() < 100 {
		t.Fatalf("unexpected ui response ct=%s len=%d", ct, rec.Body.Len())
	}
}

func TestAdminMasterMigrate(t *testing.T) {
	root := t.TempDir()
	device := "aaaaaaaaaaaaaaaa"
	s, err := store.Open(root, device)
	if err != nil {
		t.Fatal(err)
	}
	_, err = s.Handle(protocol.Frame{
		Op:      "master.pointer",
		Payload: map[string]any{"master": "bbbbbbbbbbbbbbbb", "epoch": 1},
	}, device, protocol.TrustOwner, true)
	if err != nil {
		t.Fatal(err)
	}
	srv := &admin.Server{
		Store:  s,
		Device: device,
		Auth:   admin.AuthConfig{Token: "secret"},
	}
	mux := http.NewServeMux()
	srv.Mount(mux)

	req := httptest.NewRequest(http.MethodPost, "/admin/api/master/migrate", nil)
	req.Header.Set("Authorization", "Bearer secret")
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("want 200, got %d body=%s", rec.Code, rec.Body.String())
	}
	var body map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if body["master"] != device {
		t.Fatalf("body=%v", body)
	}
	if int64(body["epoch"].(float64)) != 2 {
		t.Fatalf("epoch=%v", body["epoch"])
	}

	statsReq := httptest.NewRequest(http.MethodGet, "/admin/api/stats", nil)
	statsReq.Header.Set("Authorization", "Bearer secret")
	statsRec := httptest.NewRecorder()
	mux.ServeHTTP(statsRec, statsReq)
	var stats map[string]any
	_ = json.Unmarshal(statsRec.Body.Bytes(), &stats)
	if stats["master"] != device || int64(stats["master_epoch"].(float64)) != 2 {
		t.Fatalf("stats=%v", stats)
	}
}
