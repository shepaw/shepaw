package noise_test

import (
	"crypto/sha256"
	"encoding/hex"
	"path/filepath"
	"testing"

	"github.com/shepaw/storage-node/internal/noise"
)

func TestIdentityFingerprintStable(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "id.json")
	id, err := noise.LoadOrCreate(path)
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(id.PublicKey)
	want := hex.EncodeToString(sum[:8])
	if id.Fingerprint() != want {
		t.Fatalf("fp=%s want=%s", id.Fingerprint(), want)
	}
	id2, err := noise.LoadOrCreate(path)
	if err != nil {
		t.Fatal(err)
	}
	if id2.Fingerprint() != id.Fingerprint() {
		t.Fatal("fingerprint changed after reload")
	}
}

func TestNoiseIKRoundTrip(t *testing.T) {
	dir := t.TempDir()
	respID, err := noise.LoadOrCreate(filepath.Join(dir, "resp.json"))
	if err != nil {
		t.Fatal(err)
	}
	initID, err := noise.LoadOrCreate(filepath.Join(dir, "init.json"))
	if err != nil {
		t.Fatal(err)
	}

	initiator, err := noise.NewInitiator(initID, respID.PublicKey)
	if err != nil {
		t.Fatal(err)
	}
	responder, err := noise.NewResponder(respID)
	if err != nil {
		t.Fatal(err)
	}

	msg1, err := initiator.WriteHandshake1([]byte(`{"pairing_code":"ABCD2345","device_name":"phone","device_id":"x","timestamp":1}`))
	if err != nil {
		t.Fatal(err)
	}
	payload, peerPub, err := responder.ReadHandshake1(msg1)
	if err != nil {
		t.Fatal(err)
	}
	if string(payload) == "" || len(peerPub) != 32 {
		t.Fatal("bad hs1")
	}
	msg2, err := responder.WriteHandshake2([]byte(`{"accepted":true,"device_name":"node","device_id":"y","peer_id":"peer-1"}`))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := initiator.ReadHandshake2(msg2); err != nil {
		t.Fatal(err)
	}

	ct, err := initiator.Encrypt([]byte(`{"op":"stats","payload":{}}`))
	if err != nil {
		t.Fatal(err)
	}
	pt, err := responder.Decrypt(ct)
	if err != nil {
		t.Fatal(err)
	}
	if string(pt) != `{"op":"stats","payload":{}}` {
		t.Fatalf("got %s", pt)
	}
	ct2, err := responder.Encrypt([]byte(`{"op":"result"}`))
	if err != nil {
		t.Fatal(err)
	}
	pt2, err := initiator.Decrypt(ct2)
	if err != nil {
		t.Fatal(err)
	}
	if string(pt2) != `{"op":"result"}` {
		t.Fatalf("got %s", pt2)
	}
}

func TestEnvelopeRoundTrip(t *testing.T) {
	enc, err := noise.EncodeFrame(noise.Frame{Type: noise.FrameHS, Payload: []byte{1, 2, 3}})
	if err != nil {
		t.Fatal(err)
	}
	fr, err := noise.DecodeFrame(enc)
	if err != nil {
		t.Fatal(err)
	}
	if fr.Type != noise.FrameHS || len(fr.Payload) != 3 {
		t.Fatalf("%+v", fr)
	}
}
