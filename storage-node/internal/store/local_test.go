package store_test

import (
	"encoding/base64"
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
	begin, err := s.Handle(protocol.Frame{
		Op: "write.begin",
		Payload: map[string]any{
			"space": "artifacts",
			"path":  "task-1/hello.txt",
		},
	}, device, protocol.TrustOwner, true)
	if err != nil {
		t.Fatal(err)
	}
	id := begin["upload_id"].(string)
	payload := []byte("hello-storage-node")
	_, err = s.Handle(protocol.Frame{
		Op: "write.chunk",
		Payload: map[string]any{
			"upload_id": id,
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
		begin, err := s.Handle(protocol.Frame{
			Op: "write.begin",
			Payload: map[string]any{
				"space": "artifacts",
				"path":  path,
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
				"data":      base64.StdEncoding.EncodeToString([]byte(body)),
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
		begin, err := s.Handle(protocol.Frame{
			Op: "write.begin",
			Payload: map[string]any{
				"space": "backups",
				"path":  path,
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

	begin, err := s.Handle(protocol.Frame{
		Op: "write.begin",
		Payload: map[string]any{
			"space": "backups",
			"path":  "snap-3/f.txt",
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
			"data":      base64.StdEncoding.EncodeToString([]byte("y")),
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
