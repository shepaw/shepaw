package store_test

import (
	"encoding/base64"
	"fmt"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/shepaw/storage-node/internal/protocol"
	"github.com/shepaw/storage-node/internal/store"
)

func TestWriteCommitRead(t *testing.T) {
	root := t.TempDir()
	device := "aaaaaaaaaaaaaaaa"
	s, err := store.Open(root, device)
	if err != nil {
		t.Fatal(err)
	}
	payload := []byte("hello-storage-node")
	begin, err := s.Handle(protocol.Frame{
		Op:      "write.begin",
		Payload: writeBeginPayload("artifacts", "task-1/hello.txt", payload),
	}, device, protocol.TrustOwner, true)
	if err != nil {
		t.Fatal(err)
	}
	id := begin["upload_id"].(string)
	_, err = s.Handle(protocol.Frame{
		Op: "write.chunk",
		Payload: map[string]any{
			"upload_id": id,
			"offset":    0,
			"data":      base64.StdEncoding.EncodeToString(payload),
		},
	}, device, protocol.TrustOwner, true)
	if err != nil {
		t.Fatal(err)
	}
	commit, err := s.Handle(protocol.Frame{
		Op: "commit",
		Payload: map[string]any{
			"upload_ids": []any{id},
		},
	}, device, protocol.TrustOwner, true)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := commit["committed"]; !ok {
		t.Fatal("missing committed")
	}
	outPath := filepath.Join(root, device, "artifacts", "task-1", "hello.txt")
	if _, err := filepath.Glob(outPath); err != nil {
		t.Fatal(err)
	}
	res, err := s.Handle(protocol.Frame{
		Op: "read",
		Payload: map[string]any{
			"space":  "artifacts",
			"path":   "task-1/hello.txt",
			"offset": 0,
			"length": 64,
		},
	}, device, protocol.TrustOwner, true)
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := base64.StdEncoding.DecodeString(res["data"].(string))
	if string(raw) != string(payload) {
		t.Fatalf("got %q", raw)
	}
}

func TestDeleteRestoreRecycleEmpty(t *testing.T) {
	root := t.TempDir()
	device := "aaaaaaaaaaaaaaaa"
	s, err := store.Open(root, device)
	if err != nil {
		t.Fatal(err)
	}
	writeFile := func(path, body string) {
		t.Helper()
		raw := []byte(body)
		begin, err := s.Handle(protocol.Frame{
			Op:      "write.begin",
			Payload: writeBeginPayload("artifacts", path, raw),
		}, device, protocol.TrustOwner, true)
		if err != nil {
			t.Fatal(err)
		}
		id := begin["upload_id"].(string)
		_, err = s.Handle(protocol.Frame{
			Op: "write.chunk",
			Payload: map[string]any{
				"upload_id": id,
				"offset":    0,
				"data":      base64.StdEncoding.EncodeToString(raw),
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
	}

	writeFile("task-1/hello.txt", "hello-storage-node")
	del, err := s.Handle(protocol.Frame{
		Op: "delete",
		Payload: map[string]any{
			"space": "artifacts",
			"path":  "task-1/hello.txt",
		},
	}, device, protocol.TrustOwner, true)
	if err != nil {
		t.Fatal(err)
	}
	recycled, _ := del["recycled"].(string)
	if recycled == "" || recycled[:8] != ".recycle" {
		t.Fatalf("recycled=%q", recycled)
	}

	list, err := s.Handle(protocol.Frame{
		Op: "recycle.list", Payload: map[string]any{},
	}, device, protocol.TrustOwner, true)
	if err != nil {
		t.Fatal(err)
	}
	entriesRaw, ok := list["entries"].([]map[string]any)
	if !ok {
		t.Fatalf("entries type %T", list["entries"])
	}
	if len(entriesRaw) != 1 {
		t.Fatalf("entries=%d", len(entriesRaw))
	}
	if entriesRaw[0]["origin_path"] != "task-1/hello.txt" {
		t.Fatalf("origin=%v", entriesRaw[0]["origin_path"])
	}
	if entriesRaw[0]["recycle_path"] != recycled {
		t.Fatalf("path mismatch %v vs %s", entriesRaw[0]["recycle_path"], recycled)
	}

	_, err = s.Handle(protocol.Frame{
		Op: "recycle.restore",
		Payload: map[string]any{"recycle_path": recycled},
	}, device, protocol.TrustOwner, true)
	if err != nil {
		t.Fatal(err)
	}
	list2, _ := s.Handle(protocol.Frame{
		Op: "recycle.list", Payload: map[string]any{},
	}, device, protocol.TrustOwner, true)
	entries2 := list2["entries"].([]map[string]any)
	if len(entries2) != 0 {
		t.Fatal("expected empty recycle after restore")
	}

	writeFile("task-1/hello.txt", "v2")
	_, _ = s.Handle(protocol.Frame{
		Op: "delete",
		Payload: map[string]any{"space": "artifacts", "path": "task-1/hello.txt"},
	}, device, protocol.TrustOwner, true)
	empty, err := s.Handle(protocol.Frame{
		Op: "recycle.empty", Payload: map[string]any{},
	}, device, protocol.TrustOwner, true)
	if err != nil {
		t.Fatal(err)
	}
	var purged int64
	switch v := empty["purged_bytes"].(type) {
	case int64:
		purged = v
	case int:
		purged = int64(v)
	default:
		t.Fatalf("purged type %T", empty["purged_bytes"])
	}
	if purged <= 0 {
		t.Fatalf("purged=%d", purged)
	}

	st, err := s.Handle(protocol.Frame{
		Op: "stats", Payload: map[string]any{},
	}, device, protocol.TrustOwner, true)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := st["devices"]; !ok {
		t.Fatal("missing devices")
	}
	if _, ok := st["recycle_bytes"]; !ok {
		t.Fatal("missing recycle_bytes")
	}
}

func TestFriendRejected(t *testing.T) {
	root := t.TempDir()
	device := "aaaaaaaaaaaaaaaa"
	s, err := store.Open(root, device)
	if err != nil {
		t.Fatal(err)
	}
	_, err = s.Handle(protocol.Frame{
		Op:      "list",
		Payload: map[string]any{"space": "artifacts"},
	}, device, protocol.TrustFriend, false)
	if err == nil {
		t.Fatal("expected untrusted")
	}
	oe := err.(*store.OpError)
	if oe.Code != "untrusted" {
		t.Fatalf("code=%s", oe.Code)
	}
}

func TestCommitRetentionKeepLast(t *testing.T) {
	root := t.TempDir()
	device := "aaaaaaaaaaaaaaaa"
	s, err := store.Open(root, device)
	if err != nil {
		t.Fatal(err)
	}
	put := func(path string) {
		raw := []byte("x")
		begin, err := s.Handle(protocol.Frame{
			Op:      "write.begin",
			Payload: writeBeginPayload("backups", path, raw),
		}, device, protocol.TrustOwner, true)
		if err != nil {
			t.Fatal(err)
		}
		id := begin["upload_id"].(string)
		_, err = s.Handle(protocol.Frame{
			Op: "write.chunk",
			Payload: map[string]any{
				"upload_id": id,
				"offset":    0,
				"data":      base64.StdEncoding.EncodeToString(raw),
			},
		}, device, protocol.TrustOwner, true)
		if err != nil {
			t.Fatal(err)
		}
		_, err = s.Handle(protocol.Frame{
			Op: "commit",
			Payload: map[string]any{
				"upload_ids": []any{id},
			},
		}, device, protocol.TrustOwner, true)
		if err != nil {
			t.Fatal(err)
		}
	}
	put("snap-0/f.txt")
	time.Sleep(5 * time.Millisecond)
	put("snap-1/f.txt")
	time.Sleep(5 * time.Millisecond)
	put("snap-2/f.txt")
	time.Sleep(5 * time.Millisecond)

	rawY := []byte("y")
	begin, err := s.Handle(protocol.Frame{
		Op:      "write.begin",
		Payload: writeBeginPayload("backups", "snap-3/f.txt", rawY),
	}, device, protocol.TrustOwner, true)
	if err != nil {
		t.Fatal(err)
	}
	id := begin["upload_id"].(string)
	_, err = s.Handle(protocol.Frame{
		Op: "write.chunk",
		Payload: map[string]any{
			"upload_id": id,
			"offset":    0,
			"data":      base64.StdEncoding.EncodeToString(rawY),
		},
	}, device, protocol.TrustOwner, true)
	if err != nil {
		t.Fatal(err)
	}
	_, err = s.Handle(protocol.Frame{
		Op: "commit",
		Payload: map[string]any{
			"upload_ids": []any{id},
			"retention": map[string]any{
				"policy": "keep_last",
				"keep":   2,
			},
		},
	}, device, protocol.TrustOwner, true)
	if err != nil {
		t.Fatal(err)
	}

	ents, err := os.ReadDir(filepath.Join(root, device, "backups"))
	if err != nil {
		t.Fatal(err)
	}
	dirs := 0
	for _, e := range ents {
		if e.IsDir() && e.Name()[0] != '.' {
			dirs++
		}
	}
	if dirs != 2 {
		t.Fatalf("want 2 top-level dirs, got %d", dirs)
	}
}

func TestPurgeDevice(t *testing.T) {
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
	if err := os.WriteFile(filepath.Join(otherDir, "x.txt"), []byte("hello"), 0o644); err != nil {
		t.Fatal(err)
	}
	cursorPath := filepath.Join(root, ".system", "device_cursors.json")
	if err := os.MkdirAll(filepath.Dir(cursorPath), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(cursorPath, []byte(`{"bbbbbbbbbbbbbbbb":42,"aaaaaaaaaaaaaaaa":1}`), 0o644); err != nil {
		t.Fatal(err)
	}

	if _, err := s.PurgeDevice(self, self); err == nil {
		t.Fatal("expected cannot purge self")
	}
	freed, err := s.PurgeDevice(other, self)
	if err != nil {
		t.Fatal(err)
	}
	if freed <= 0 {
		t.Fatalf("freed=%d", freed)
	}
	if _, err := os.Stat(filepath.Join(root, other)); !os.IsNotExist(err) {
		t.Fatalf("other dir still exists: %v", err)
	}
	raw, err := os.ReadFile(cursorPath)
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatal(err)
	}
	if _, ok := m[other]; ok {
		t.Fatalf("cursor still has other: %s", raw)
	}
	if _, ok := m[self]; !ok {
		t.Fatalf("cursor lost self: %s", raw)
	}
}

func TestAdminListDelete(t *testing.T) {
	root := t.TempDir()
	self := "aaaaaaaaaaaaaaaa"
	other := "bbbbbbbbbbbbbbbb"
	s, err := store.Open(root, self)
	if err != nil {
		t.Fatal(err)
	}
	otherDir := filepath.Join(root, other, "attachments")
	if err := os.MkdirAll(otherDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(otherDir, "secret.bin"), []byte("secret"), 0o644); err != nil {
		t.Fatal(err)
	}

	listed, err := s.AdminList(other, "attachments", "")
	if err != nil {
		t.Fatal(err)
	}
	ents := listed["entries"].([]map[string]any)
	if len(ents) != 1 {
		t.Fatalf("entries=%v", listed)
	}

	del, err := s.AdminDelete(other, "attachments", "secret.bin")
	if err != nil {
		t.Fatal(err)
	}
	if del["recycled"] == nil {
		t.Fatalf("%v", del)
	}
	listed2, _ := s.AdminList(other, "attachments", "")
	ents2 := listed2["entries"].([]map[string]any)
	if len(ents2) != 0 {
		t.Fatalf("still listed: %v", listed2)
	}
}

func TestWipeSelf(t *testing.T) {
	root := t.TempDir()
	self := "aaaaaaaaaaaaaaaa"
	other := "bbbbbbbbbbbbbbbb"
	s, err := store.Open(root, self)
	if err != nil {
		t.Fatal(err)
	}
	selfDir := filepath.Join(root, self, "files")
	if err := os.MkdirAll(selfDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(selfDir, "a.txt"), []byte("data"), 0o644); err != nil {
		t.Fatal(err)
	}
	otherDir := filepath.Join(root, other, "files")
	if err := os.MkdirAll(otherDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(otherDir, "keep.txt"), []byte("keep"), 0o644); err != nil {
		t.Fatal(err)
	}
	recycle := filepath.Join(root, ".recycle", "x")
	_ = os.MkdirAll(recycle, 0o755)

	freed, err := s.WipeSelf(self)
	if err != nil {
		t.Fatal(err)
	}
	if freed <= 0 {
		t.Fatalf("freed=%d", freed)
	}
	if _, err := os.Stat(filepath.Join(selfDir, "a.txt")); !os.IsNotExist(err) {
		t.Fatal("self file should be gone")
	}
	if _, err := os.Stat(filepath.Join(root, self)); err != nil {
		t.Fatal("self dir should be recreated")
	}
	if _, err := os.Stat(filepath.Join(otherDir, "keep.txt")); err != nil {
		t.Fatal("other mirror must remain")
	}
	if _, err := os.Stat(recycle); err != nil {
		t.Fatal("recycle must remain")
	}
	if _, err := s.WipeSelf(other); err == nil {
		t.Fatal("cannot wipe other as self")
	}
}

func TestSyncHelloAndUptoSeq(t *testing.T) {
	root := t.TempDir()
	device := "aaaaaaaaaaaaaaaa"
	s, err := store.Open(root, device)
	if err != nil {
		t.Fatal(err)
	}

	hello, err := s.Handle(protocol.Frame{
		Op:      "sync.hello",
		Payload: map[string]any{"device": device},
	}, device, protocol.TrustOwner, false)
	if err != nil {
		t.Fatal(err)
	}
	if hello["applied_seq"].(int64) != 0 {
		t.Fatalf("want 0, got %v", hello["applied_seq"])
	}

	rawHi := []byte("hi")
	begin, err := s.Handle(protocol.Frame{
		Op:      "write.begin",
		Payload: writeBeginPayload("files", "sync.txt", rawHi),
	}, device, protocol.TrustOwner, true)
	if err != nil {
		t.Fatal(err)
	}
	id := begin["upload_id"].(string)
	_, err = s.Handle(protocol.Frame{
		Op: "write.chunk",
		Payload: map[string]any{
			"upload_id": id,
			"offset":    0,
			"data":      base64.StdEncoding.EncodeToString(rawHi),
		},
	}, device, protocol.TrustOwner, true)
	if err != nil {
		t.Fatal(err)
	}
	commit, err := s.Handle(protocol.Frame{
		Op: "commit",
		Payload: map[string]any{
			"upload_ids": []any{id},
			"upto_seq":   7,
		},
	}, device, protocol.TrustOwner, true)
	if err != nil {
		t.Fatal(err)
	}
	if commit["applied_seq"].(int64) != 7 {
		t.Fatalf("applied=%v", commit["applied_seq"])
	}

	hello2, err := s.Handle(protocol.Frame{
		Op:      "sync.hello",
		Payload: map[string]any{"device": device},
	}, device, protocol.TrustOwner, false)
	if err != nil {
		t.Fatal(err)
	}
	if hello2["applied_seq"].(int64) != 7 {
		t.Fatalf("hello2=%v", hello2)
	}

	// only advance forward
	commit2, err := s.Handle(protocol.Frame{
		Op: "commit",
		Payload: map[string]any{
			"upload_ids": []any{},
			"upto_seq":   3,
		},
	}, device, protocol.TrustOwner, true)
	if err != nil {
		t.Fatal(err)
	}
	if commit2["applied_seq"].(int64) != 7 {
		t.Fatalf("should not regress: %v", commit2)
	}

	_, err = s.Handle(protocol.Frame{
		Op: "delete",
		Payload: map[string]any{
			"space":    "files",
			"path":     "sync.txt",
			"upto_seq": 9,
		},
	}, device, protocol.TrustOwner, true)
	if err != nil {
		t.Fatal(err)
	}
	cursors, err := s.Handle(protocol.Frame{Op: "sync.cursors"}, device, protocol.TrustOwner, true)
	if err != nil {
		t.Fatal(err)
	}
	m := cursors["cursors"].(map[string]any)
	if m[device].(int64) != 9 {
		t.Fatalf("cursors=%v", cursors)
	}
}

func TestGcStagingAndRecycle(t *testing.T) {
	root := t.TempDir()
	device := "aaaaaaaaaaaaaaaa"
	s, err := store.Open(root, device)
	if err != nil {
		t.Fatal(err)
	}
	staging := filepath.Join(root, device, "files", ".staging")
	if err := os.MkdirAll(staging, 0o755); err != nil {
		t.Fatal(err)
	}
	oldTime := time.Now().Add(-48 * time.Hour)
	// Legacy dir layout
	oldDir := filepath.Join(staging, "old-upload")
	_ = os.MkdirAll(oldDir, 0o755)
	_ = os.WriteFile(filepath.Join(oldDir, "blob"), []byte("x"), 0o644)
	_ = os.Chtimes(oldDir, oldTime, oldTime)
	// Flat .part/.json layout (created_ms in meta)
	_ = os.WriteFile(filepath.Join(staging, "flat-old.part"), []byte("y"), 0o644)
	_ = os.WriteFile(filepath.Join(staging, "flat-old.json"),
		[]byte(`{"path":"a.txt","size":1,"sha256":"00","created_ms":1}`), 0o644)
	freshPart := filepath.Join(staging, "fresh.part")
	freshJSON := filepath.Join(staging, "fresh.json")
	_ = os.WriteFile(freshPart, []byte("z"), 0o644)
	_ = os.WriteFile(freshJSON,
		[]byte(fmt.Sprintf(`{"path":"b.txt","size":1,"sha256":"00","created_ms":%d}`, time.Now().UnixMilli())), 0o644)

	n, err := s.GcStaging(24 * time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	if n != 2 {
		t.Fatalf("staging removed=%d want 2", n)
	}
	if _, err := os.Stat(oldDir); !os.IsNotExist(err) {
		t.Fatal("old staging dir should be gone")
	}
	if _, err := os.Stat(filepath.Join(staging, "flat-old.json")); !os.IsNotExist(err) {
		t.Fatal("old flat staging should be gone")
	}
	if _, err := os.Stat(freshJSON); err != nil {
		t.Fatal("fresh staging should remain")
	}

	oldRecycle := filepath.Join(root, ".recycle", "2020-01-01", device, "files")
	_ = os.MkdirAll(oldRecycle, 0o755)
	_ = os.WriteFile(filepath.Join(oldRecycle, "gone.txt"), []byte("bye"), 0o644)
	b, err := s.GcRecycle(30 * 24 * time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	if b <= 0 {
		t.Fatalf("recycle purged=%d", b)
	}
	if _, err := os.Stat(filepath.Join(root, ".recycle", "2020-01-01")); !os.IsNotExist(err) {
		t.Fatal("old recycle date dir should be gone")
	}
}

func TestPurgeDeviceNotFound(t *testing.T) {
	root := t.TempDir()
	self := "aaaaaaaaaaaaaaaa"
	s, err := store.Open(root, self)
	if err != nil {
		t.Fatal(err)
	}
	_, err = s.PurgeDevice("cccccccccccccccc", self)
	if err == nil {
		t.Fatal("expected not_found")
	}
}
