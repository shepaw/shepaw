package store_test

import (
	"encoding/base64"
	"strings"
	"testing"

	"github.com/shepaw/storage-node/internal/protocol"
	"github.com/shepaw/storage-node/internal/store"
)

func TestSpaceSearchEventsQuota(t *testing.T) {
	root := t.TempDir()
	device := "aaaaaaaaaaaaaaaa"
	s, err := store.Open(root, device)
	if err != nil {
		t.Fatal(err)
	}

	declared, err := s.Handle(protocol.Frame{
		Op: "space.declare",
		Payload: map[string]any{
			"name": "models", "visibility": "shared",
		},
	}, device, protocol.TrustOwner, true)
	if err != nil {
		t.Fatal(err)
	}
	space, _ := declared["space"].(map[string]any)
	if space["name"] != "models" {
		t.Fatalf("declare: %v", declared)
	}

	remote, err := s.Handle(protocol.Frame{
		Op:      "space.declare",
		Payload: map[string]any{"name": "vault", "visibility": "private"},
	}, device, protocol.TrustOwner, false)
	if err == nil {
		t.Fatal("expected remote declare denied")
	}
	if oe, ok := err.(*store.OpError); !ok || oe.Code != "acl_denied" {
		t.Fatalf("remote declare: %v", err)
	}
	_ = remote

	listed, err := s.Handle(protocol.Frame{Op: "space.list"}, device, protocol.TrustOwner, false)
	if err != nil {
		t.Fatal(err)
	}
	names := []string{}
	if arr, ok := listed["spaces"].([]map[string]any); ok {
		for _, m := range arr {
			n, _ := m["name"].(string)
			names = append(names, n)
		}
	} else if arr, ok := listed["spaces"].([]any); ok {
		for _, item := range arr {
			m, _ := item.(map[string]any)
			n, _ := m["name"].(string)
			names = append(names, n)
		}
	}
	joined := strings.Join(names, ",")
	if !strings.Contains(joined, "models") || !strings.Contains(joined, "files") {
		t.Fatalf("space.list names=%v", names)
	}

	body := []byte("hello search-needle-zeta")
	begin, err := s.Handle(protocol.Frame{
		Op:      "write.begin",
		Payload: writeBeginPayload("files", "p2ops/zeta.txt", body),
	}, device, protocol.TrustOwner, true)
	if err != nil {
		t.Fatal(err)
	}
	id := begin["upload_id"].(string)
	if _, err = s.Handle(protocol.Frame{
		Op: "write.chunk",
		Payload: map[string]any{
			"upload_id": id, "offset": 0,
			"data": base64.StdEncoding.EncodeToString(body),
		},
	}, device, protocol.TrustOwner, true); err != nil {
		t.Fatal(err)
	}
	if _, err = s.Handle(protocol.Frame{
		Op:      "commit",
		Payload: map[string]any{"upload_ids": []any{id}},
	}, device, protocol.TrustOwner, true); err != nil {
		t.Fatal(err)
	}

	found, err := s.Handle(protocol.Frame{
		Op:      "search",
		Payload: map[string]any{"q": "zeta", "space": "files"},
	}, device, protocol.TrustOwner, true)
	if err != nil {
		t.Fatal(err)
	}
	if n := int(numAny(found["total"])); n < 1 {
		t.Fatalf("search total=%v data=%v", found["total"], found)
	}

	unknown, err := s.Handle(protocol.Frame{
		Op:      "search",
		Payload: map[string]any{"q": "x", "space": "mystery"},
	}, device, protocol.TrustOwner, true)
	if err == nil {
		t.Fatal("expected unknown space")
	}
	if oe, ok := err.(*store.OpError); !ok || oe.Code != "bad_op" {
		t.Fatalf("unknown space: %v %v", err, unknown)
	}

	events, err := s.Handle(protocol.Frame{
		Op:      "events.list",
		Payload: map[string]any{"since": 0, "kind": "file.committed"},
	}, device, protocol.TrustOwner, true)
	if err != nil {
		t.Fatal(err)
	}
	if int(numAny(events["latest_seq"])) < 1 {
		t.Fatalf("events: %v", events)
	}

	s.AgentQuotaBytes = 20
	big := []byte("this payload is definitely over twenty bytes long")
	_, err = s.Handle(protocol.Frame{
		Op:      "write.begin",
		Payload: writeBeginPayload("artifacts", "p2ops/too-big.bin", big),
	}, device, protocol.TrustOwner, true)
	if err == nil {
		t.Fatal("expected quota_exceeded")
	}
	if oe, ok := err.(*store.OpError); !ok || oe.Code != "quota_exceeded" {
		t.Fatalf("quota: %v", err)
	}
}

func numAny(v any) float64 {
	switch t := v.(type) {
	case float64:
		return t
	case int:
		return float64(t)
	case int64:
		return float64(t)
	default:
		return 0
	}
}
