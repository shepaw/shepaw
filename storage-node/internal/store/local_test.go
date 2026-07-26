package store_test

import (
	"encoding/base64"
	"path/filepath"
	"testing"

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
	_, err = s.Handle(protocol.Frame{
		Op: "commit",
		Payload: map[string]any{
			"upload_ids": []any{id},
		},
	}, device, protocol.TrustOwner, true)
	if err != nil {
		t.Fatal(err)
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
