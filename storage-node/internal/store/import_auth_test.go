package store_test

import (
	"encoding/base64"
	"testing"

	"github.com/shepaw/storage-node/internal/protocol"
	"github.com/shepaw/storage-node/internal/store"
)

func TestImportRequestGrantAndPrivateRead(t *testing.T) {
	root := t.TempDir()
	master := "aaaaaaaaaaaaaaaa"
	oldDev := "bbbbbbbbbbbbbbbb"
	newDev := "cccccccccccccccc"
	s, err := store.Open(root, master)
	if err != nil {
		t.Fatal(err)
	}

	// seed old device private file on this master mirror
	begin, err := s.Handle(protocol.Frame{
		Op: "write.begin",
		Payload: map[string]any{
			"space": "backups",
			"path":  "snap/manifest.json",
		},
	}, oldDev, protocol.TrustOwner, true)
	if err != nil {
		t.Fatal(err)
	}
	id := begin["upload_id"].(string)
	_, err = s.Handle(protocol.Frame{
		Op: "write.chunk",
		Payload: map[string]any{
			"upload_id": id,
			"data":      base64.StdEncoding.EncodeToString([]byte(`{"ok":true}`)),
		},
	}, oldDev, protocol.TrustOwner, true)
	if err != nil {
		t.Fatal(err)
	}
	_, err = s.Handle(protocol.Frame{
		Op:      "commit",
		Payload: map[string]any{"upload_ids": []any{id}},
	}, oldDev, protocol.TrustOwner, true)
	if err != nil {
		t.Fatal(err)
	}

	// new device requests import of old device
	reqRes, err := s.Handle(protocol.Frame{
		Op:      "import.request",
		Payload: map[string]any{"old_device": oldDev},
	}, newDev, protocol.TrustOwner, false)
	if err != nil {
		t.Fatal(err)
	}
	requestID := reqRes["request_id"].(string)

	pending, err := s.Handle(protocol.Frame{Op: "import.pending"}, master, protocol.TrustOwner, true)
	if err != nil {
		t.Fatal(err)
	}
	switch reqs := pending["requests"].(type) {
	case []any:
		if len(reqs) != 1 {
			t.Fatalf("pending=%v", pending)
		}
	case []map[string]any:
		if len(reqs) != 1 {
			t.Fatalf("pending=%v", pending)
		}
	default:
		t.Fatalf("pending type %T: %v", pending["requests"], pending)
	}

	// private read without grant must fail
	_, err = s.Handle(protocol.Frame{
		Op: "read",
		Payload: map[string]any{
			"space":  "backups",
			"device": oldDev,
			"path":   "snap/manifest.json",
			"offset": 0,
			"length": 64,
		},
	}, newDev, protocol.TrustOwner, false)
	if err == nil {
		t.Fatal("expected acl deny without grant")
	}

	grantRes, err := s.Handle(protocol.Frame{
		Op:      "import.grant",
		Payload: map[string]any{"request_id": requestID},
	}, master, protocol.TrustOwner, true)
	if err != nil {
		t.Fatal(err)
	}
	grant := grantRes["grant"].(map[string]any)
	grantID := grant["grant_id"].(string)

	readRes, err := s.Handle(protocol.Frame{
		Op: "read",
		Payload: map[string]any{
			"space":  "backups",
			"device": oldDev,
			"path":   "snap/manifest.json",
			"offset": 0,
			"length": 64,
			"grant":  grantID,
		},
	}, newDev, protocol.TrustOwner, false)
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := base64.StdEncoding.DecodeString(readRes["data"].(string))
	if string(raw) != `{"ok":true}` {
		t.Fatalf("got %q", raw)
	}

	_, err = s.Handle(protocol.Frame{
		Op:      "import.reject",
		Payload: map[string]any{"request_id": "ir-missing"},
	}, master, protocol.TrustOwner, true)
	if err != nil {
		t.Fatal(err)
	}
}
