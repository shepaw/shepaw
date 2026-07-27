package store_test

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"os"
	"path/filepath"
	"testing"

	"github.com/shepaw/storage-node/internal/protocol"
	"github.com/shepaw/storage-node/internal/store"
)

type fakeRPC struct {
	has     map[string]bool
	cursors map[string]any
	list    map[string]any
	reads   map[string][]byte // key device|space|path
}

func (f *fakeRPC) Has(deviceID string) bool { return f.has[deviceID] }

func (f *fakeRPC) Call(deviceID, op string, payload map[string]any) (map[string]any, error) {
	switch op {
	case "sync.cursors":
		return map[string]any{"cursors": f.cursors}, nil
	case "stats":
		devices := map[string]any{}
		for id := range f.cursors {
			devices[id] = map[string]any{}
		}
		return map[string]any{"devices": devices}, nil
	case "list":
		space, _ := payload["space"].(string)
		if space != "files" {
			return map[string]any{"entries": []any{}}, nil
		}
		return f.list, nil
	case "read":
		device, _ := payload["device"].(string)
		space, _ := payload["space"].(string)
		path, _ := payload["path"].(string)
		key := device + "|" + space + "|" + path
		data := f.reads[key]
		offset := int64(0)
		switch v := payload["offset"].(type) {
		case int64:
			offset = v
		case float64:
			offset = int64(v)
		case int:
			offset = int64(v)
		}
		if offset >= int64(len(data)) {
			return map[string]any{"data": "", "size": 0, "eof": true}, nil
		}
		chunk := data[offset:]
		if len(chunk) > 65536 {
			chunk = chunk[:65536]
		}
		eof := offset+int64(len(chunk)) >= int64(len(data))
		return map[string]any{
			"data": base64.StdEncoding.EncodeToString(chunk),
			"size": len(chunk),
			"eof":  eof,
		}, nil
	default:
		return nil, nil
	}
}

func TestMasterMigrateSeedsFromLivePeerRPC(t *testing.T) {
	root := t.TempDir()
	self := "aaaaaaaaaaaaaaaa"
	old := "bbbbbbbbbbbbbbbb"
	other := "cccccccccccccccc"
	s, err := store.Open(root, self)
	if err != nil {
		t.Fatal(err)
	}
	_, err = s.Handle(protocol.Frame{
		Op:      "master.pointer",
		Payload: map[string]any{"master": old, "epoch": 2},
	}, self, protocol.TrustOwner, true)
	if err != nil {
		t.Fatal(err)
	}

	payload := []byte("seeded-mirror-bytes")
	h := sha256.Sum256(payload)
	sha := hex.EncodeToString(h[:])

	rpc := &fakeRPC{
		has:     map[string]bool{old: true},
		cursors: map[string]any{other: float64(7)},
		list: map[string]any{
			"entries": []any{
				map[string]any{
					"path": "note.txt", "size": len(payload), "sha256": sha,
				},
			},
		},
		reads: map[string][]byte{
			other + "|files|note.txt": payload,
		},
	}
	s.SetPeerRPC(rpc)

	res, err := s.Handle(protocol.Frame{Op: "master.migrate"}, self, protocol.TrustOwner, true)
	if err != nil {
		t.Fatal(err)
	}
	if res["old_master_reachable"] != true {
		t.Fatalf("reachable=%v", res["old_master_reachable"])
	}
	if res["seeded_files"].(int) != 1 {
		t.Fatalf("seeded=%v", res["seeded_files"])
	}
	gate, _ := res["hash_gate"].(map[string]any)
	if gate["ran"] != true || gate["ok"] != true {
		t.Fatalf("hash_gate=%v", gate)
	}
	if gate["mismatch_count"].(int) != 0 {
		t.Fatalf("mismatches=%v", gate)
	}
	if res["master"] != self || res["epoch"].(int64) != 3 {
		t.Fatalf("res=%v", res)
	}
	cursors := res["cursors"].(map[string]any)
	if anyToInt64Test(cursors[other]) != 7 {
		t.Fatalf("cursors=%v", cursors)
	}
	got, err := os.ReadFile(filepath.Join(root, other, "files", "note.txt"))
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != string(payload) {
		t.Fatalf("got=%q", got)
	}
}

func anyToInt64Test(v any) int64 {
	switch x := v.(type) {
	case int64:
		return x
	case int:
		return int64(x)
	case float64:
		return int64(x)
	default:
		return 0
	}
}

func TestMasterMigrateHashGateMissingLocal(t *testing.T) {
	root := t.TempDir()
	self := "aaaaaaaaaaaaaaaa"
	old := "bbbbbbbbbbbbbbbb"
	other := "cccccccccccccccc"
	s, err := store.Open(root, self)
	if err != nil {
		t.Fatal(err)
	}
	_, err = s.Handle(protocol.Frame{
		Op:      "master.pointer",
		Payload: map[string]any{"master": old, "epoch": 1},
	}, self, protocol.TrustOwner, true)
	if err != nil {
		t.Fatal(err)
	}

	// Remote claims a file; seed will write it — then we delete local to force missing_local on re-gate.
	// Simpler: list returns file but read returns empty / seed skipped by not providing read data
	// so seed writes 0 files, hash gate sees missing_local.
	payload := []byte("remote-only")
	h := sha256.Sum256(payload)
	sha := hex.EncodeToString(h[:])
	rpc := &fakeRPC{
		has:     map[string]bool{old: true},
		cursors: map[string]any{other: float64(1)},
		list: map[string]any{
			"entries": []any{
				map[string]any{"path": "only-remote.txt", "size": len(payload), "sha256": sha},
			},
		},
		reads: map[string][]byte{}, // no read → seed skip → missing_local
	}
	s.SetPeerRPC(rpc)

	res, err := s.Handle(protocol.Frame{Op: "master.migrate"}, self, protocol.TrustOwner, true)
	if err != nil {
		t.Fatal(err)
	}
	gate := res["hash_gate"].(map[string]any)
	if gate["ran"] != true || gate["ok"] != false {
		t.Fatalf("gate=%v", gate)
	}
	if gate["mismatch_count"].(int) < 1 {
		t.Fatalf("expected mismatches: %v", gate)
	}

	// hard block
	_, err = s.Handle(protocol.Frame{
		Op: "master.pointer", Payload: map[string]any{"master": old, "epoch": 5},
	}, self, protocol.TrustOwner, true)
	if err != nil {
		t.Fatal(err)
	}
	_, err = s.Handle(protocol.Frame{
		Op:      "master.migrate",
		Payload: map[string]any{"require_hash_match": true},
	}, self, protocol.TrustOwner, true)
	if err == nil {
		t.Fatal("expected hash_gate hard fail")
	}
	if oe, ok := err.(*store.OpError); !ok || oe.Code != "hash_gate" {
		t.Fatalf("err=%v", err)
	}
}
