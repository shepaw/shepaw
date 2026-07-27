package store_test

import (
	"testing"

	"github.com/shepaw/storage-node/internal/protocol"
	"github.com/shepaw/storage-node/internal/store"
)

func TestMasterPointerQueryDefault(t *testing.T) {
	root := t.TempDir()
	device := "aaaaaaaaaaaaaaaa"
	s, err := store.Open(root, device)
	if err != nil {
		t.Fatal(err)
	}
	res, err := s.Handle(protocol.Frame{Op: "master.pointer.query"}, device, protocol.TrustOwner, true)
	if err != nil {
		t.Fatal(err)
	}
	if res["master"] != device {
		t.Fatalf("master=%v", res["master"])
	}
	if res["epoch"].(int64) != 0 {
		t.Fatalf("epoch=%v", res["epoch"])
	}
}

func TestMasterPointerApplyAdvances(t *testing.T) {
	root := t.TempDir()
	device := "aaaaaaaaaaaaaaaa"
	other := "bbbbbbbbbbbbbbbb"
	s, err := store.Open(root, device)
	if err != nil {
		t.Fatal(err)
	}
	res, err := s.Handle(protocol.Frame{
		Op: "master.pointer",
		Payload: map[string]any{
			"master": other,
			"epoch":  3,
		},
	}, device, protocol.TrustOwner, true)
	if err != nil {
		t.Fatal(err)
	}
	if res["applied"] != true {
		t.Fatalf("res=%v", res)
	}
	q, err := s.Handle(protocol.Frame{Op: "master.pointer.query"}, device, protocol.TrustOwner, true)
	if err != nil {
		t.Fatal(err)
	}
	if q["master"] != other || q["epoch"].(int64) != 3 {
		t.Fatalf("q=%v", q)
	}

	// stale
	stale, err := s.Handle(protocol.Frame{
		Op: "master.pointer",
		Payload: map[string]any{
			"master": device,
			"epoch":  2,
		},
	}, device, protocol.TrustOwner, true)
	if err != nil {
		t.Fatal(err)
	}
	if stale["applied"] != false || stale["reason"] != "stale" {
		t.Fatalf("stale=%v", stale)
	}

	// same epoch different master → apply (Dart race rule)
	race, err := s.Handle(protocol.Frame{
		Op: "master.pointer",
		Payload: map[string]any{
			"master": device,
			"epoch":  3,
		},
	}, device, protocol.TrustOwner, true)
	if err != nil {
		t.Fatal(err)
	}
	if race["applied"] != true {
		t.Fatalf("race=%v", race)
	}
	q2, _ := s.Handle(protocol.Frame{Op: "master.pointer.query"}, device, protocol.TrustOwner, true)
	if q2["master"] != device {
		t.Fatalf("q2=%v", q2)
	}

	stats, err := s.Handle(protocol.Frame{Op: "stats"}, device, protocol.TrustOwner, true)
	if err != nil {
		t.Fatal(err)
	}
	if stats["master"] != device || stats["master_epoch"].(int64) != 3 {
		t.Fatalf("stats pointer=%v", stats)
	}
}
