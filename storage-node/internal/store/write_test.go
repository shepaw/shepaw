package store_test

import (
	"encoding/base64"
	"os"
	"path/filepath"
	"testing"

	"github.com/shepaw/storage-node/internal/protocol"
	"github.com/shepaw/storage-node/internal/store"
)

func TestWriteResumeAndHashMismatch(t *testing.T) {
	root := t.TempDir()
	device := "aaaaaaaaaaaaaaaa"
	s, err := store.Open(root, device)
	if err != nil {
		t.Fatal(err)
	}
	body := []byte("abcdefghij")
	begin, err := s.Handle(protocol.Frame{
		Op:      "write.begin",
		Payload: writeBeginPayload("files", "r.txt", body),
	}, device, protocol.TrustOwner, true)
	if err != nil {
		t.Fatal(err)
	}
	id := begin["upload_id"].(string)
	half := body[:5]
	chunk, err := s.Handle(protocol.Frame{
		Op: "write.chunk",
		Payload: map[string]any{
			"upload_id": id,
			"offset":    0,
			"data":      base64.StdEncoding.EncodeToString(half),
		},
	}, device, protocol.TrustOwner, true)
	if err != nil {
		t.Fatal(err)
	}
	if int(chunk["received"].(int64)) != 5 && int(chunk["received"].(float64)) != 5 {
		// JSON numbers may be float64 or we use int from map — accept either via num
		rec := chunk["received"]
		switch v := rec.(type) {
		case int:
			if v != 5 {
				t.Fatalf("received=%v", rec)
			}
		case int64:
			if v != 5 {
				t.Fatalf("received=%v", rec)
			}
		case float64:
			if int(v) != 5 {
				t.Fatalf("received=%v", rec)
			}
		default:
			t.Fatalf("received type %T", rec)
		}
	}
	// resume
	begin2, err := s.Handle(protocol.Frame{
		Op: "write.begin",
		Payload: map[string]any{
			"space": "files", "path": "r.txt", "size": len(body),
			"sha256": testSHA(body), "upload_id": id,
		},
	}, device, protocol.TrustOwner, true)
	if err != nil {
		t.Fatal(err)
	}
	rec := begin2["received"]
	var received int
	switch v := rec.(type) {
	case int:
		received = v
	case int64:
		received = int(v)
	case float64:
		received = int(v)
	}
	if received != 5 {
		t.Fatalf("resume received=%v", rec)
	}
	_, err = s.Handle(protocol.Frame{
		Op: "write.chunk",
		Payload: map[string]any{
			"upload_id": id,
			"offset":    5,
			"data":      base64.StdEncoding.EncodeToString(body[5:]),
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

	// hash mismatch: declare wrong sha
	bad := []byte("xx")
	beginBad, err := s.Handle(protocol.Frame{
		Op: "write.begin",
		Payload: map[string]any{
			"space": "files", "path": "bad.txt", "size": 2,
			"sha256": testSHA([]byte("yy")),
		},
	}, device, protocol.TrustOwner, true)
	if err != nil {
		t.Fatal(err)
	}
	bid := beginBad["upload_id"].(string)
	_, _ = s.Handle(protocol.Frame{
		Op: "write.chunk",
		Payload: map[string]any{
			"upload_id": bid, "offset": 0,
			"data": base64.StdEncoding.EncodeToString(bad),
		},
	}, device, protocol.TrustOwner, true)
	_, err = s.Handle(protocol.Frame{
		Op:      "commit",
		Payload: map[string]any{"upload_ids": []any{bid}},
	}, device, protocol.TrustOwner, true)
	if err == nil {
		t.Fatal("expected hash_mismatch")
	}
	if oe, ok := err.(*store.OpError); !ok || oe.Code != "hash_mismatch" {
		t.Fatalf("err=%v", err)
	}
}

func TestCommitOverwriteRecycles(t *testing.T) {
	root := t.TempDir()
	device := "aaaaaaaaaaaaaaaa"
	s, err := store.Open(root, device)
	if err != nil {
		t.Fatal(err)
	}
	put := func(body string) {
		t.Helper()
		raw := []byte(body)
		begin, err := s.Handle(protocol.Frame{
			Op:      "write.begin",
			Payload: writeBeginPayload("files", "same.txt", raw),
		}, device, protocol.TrustOwner, true)
		if err != nil {
			t.Fatal(err)
		}
		id := begin["upload_id"].(string)
		_, err = s.Handle(protocol.Frame{
			Op: "write.chunk",
			Payload: map[string]any{
				"upload_id": id, "offset": 0,
				"data": base64.StdEncoding.EncodeToString(raw),
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
	put("v1")
	put("v2")
	data, _ := os.ReadFile(filepath.Join(root, device, "files", "same.txt"))
	if string(data) != "v2" {
		t.Fatalf("got %q", data)
	}
	rec, err := s.Handle(protocol.Frame{Op: "recycle.list"}, device, protocol.TrustOwner, true)
	if err != nil {
		t.Fatal(err)
	}
	entries := rec["entries"].([]map[string]any)
	if len(entries) < 1 {
		t.Fatal("expected recycled old version")
	}
}

func TestNotMasterFence(t *testing.T) {
	root := t.TempDir()
	device := "aaaaaaaaaaaaaaaa"
	other := "bbbbbbbbbbbbbbbb"
	s, err := store.Open(root, device)
	if err != nil {
		t.Fatal(err)
	}
	_, err = s.Handle(protocol.Frame{
		Op:      "master.pointer",
		Payload: map[string]any{"master": other, "epoch": int64(2)},
	}, other, protocol.TrustOwner, false)
	if err != nil {
		t.Fatal(err)
	}
	_, err = s.Handle(protocol.Frame{
		Op:      "sync.hello",
		Payload: map[string]any{"device": device},
	}, device, protocol.TrustOwner, false)
	if err == nil {
		t.Fatal("expected not_master")
	}
	if oe, ok := err.(*store.OpError); !ok || oe.Code != "not_master" {
		t.Fatalf("err=%v", err)
	}
}

func TestDeleteIdempotent(t *testing.T) {
	root := t.TempDir()
	device := "aaaaaaaaaaaaaaaa"
	s, err := store.Open(root, device)
	if err != nil {
		t.Fatal(err)
	}
	out, err := s.Handle(protocol.Frame{
		Op: "delete",
		Payload: map[string]any{
			"space": "files", "path": "missing.txt", "upto_seq": 3,
		},
	}, device, protocol.TrustOwner, true)
	if err != nil {
		t.Fatal(err)
	}
	if out["already_gone"] != true {
		t.Fatalf("out=%v", out)
	}
	if out["applied_seq"].(int64) != 3 {
		t.Fatalf("applied=%v", out["applied_seq"])
	}
}
