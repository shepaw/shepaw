package peer

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	"github.com/shepaw/storage-node/internal/noise"
	"github.com/shepaw/storage-node/internal/protocol"
	"github.com/shepaw/storage-node/internal/store"
)

func TestReconnectKnownPeer(t *testing.T) {
	root := t.TempDir()
	nodeID, err := noise.LoadOrCreate(root + "/node.json")
	if err != nil {
		t.Fatal(err)
	}
	clientID, err := noise.LoadOrCreate(root + "/client.json")
	if err != nil {
		t.Fatal(err)
	}
	st, err := store.Open(root+"/data", nodeID.Fingerprint())
	if err != nil {
		t.Fatal(err)
	}
	peers := NewStore(root)
	if err := peers.Upsert(Peer{
		Fingerprint:  clientID.Fingerprint(),
		PublicKeyB64: clientID.PublicKeyBase64(),
		DeviceName:   "phone",
		PeerID:       "peer-test",
		TrustLevel:   protocol.TrustOwner,
		PairedAtMs:   NowMs(),
	}); err != nil {
		t.Fatal(err)
	}

	srv := &Server{
		Store:      st,
		Hub:        NewPairingHub(nodeID, peers, "node"),
		Peers:      peers,
		Identity:   nodeID,
		DeviceName: "node",
	}
	hs := httptest.NewServer(http.HandlerFunc(srv.HandleWS))
	defer hs.Close()

	wsURL := "ws" + strings.TrimPrefix(hs.URL, "http") + "/peer/ws"
	conn, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()

	initSess, err := noise.NewInitiator(clientID, nodeID.PublicKey)
	if err != nil {
		t.Fatal(err)
	}
	msg1Payload, _ := json.Marshal(map[string]any{
		"type":      "reconnect",
		"device_id": clientID.Fingerprint(),
	})
	msg1, err := initSess.WriteHandshake1(msg1Payload)
	if err != nil {
		t.Fatal(err)
	}
	frame1, err := noise.EncodeFrame(noise.Frame{Type: noise.FrameHS, Payload: msg1})
	if err != nil {
		t.Fatal(err)
	}
	if err := conn.WriteMessage(websocket.TextMessage, []byte(frame1)); err != nil {
		t.Fatal(err)
	}

	_ = conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	_, raw2, err := conn.ReadMessage()
	if err != nil {
		t.Fatal(err)
	}
	fr2, err := noise.DecodeFrame(string(raw2))
	if err != nil || fr2.Type != noise.FrameHS {
		t.Fatalf("expected hs frame: %v %#v", err, fr2)
	}
	ackPayload, err := initSess.ReadHandshake2(fr2.Payload)
	if err != nil {
		t.Fatal(err)
	}
	var ack map[string]any
	if err := json.Unmarshal(ackPayload, &ack); err != nil {
		t.Fatal(err)
	}
	if ack["type"] != "reconnect_ack" {
		t.Fatalf("ack=%v", ack)
	}

	req, _ := json.Marshal(map[string]any{
		"op":      "stats",
		"payload": map[string]any{},
	})
	ct, err := initSess.Encrypt(req)
	if err != nil {
		t.Fatal(err)
	}
	enc, err := noise.EncodeFrame(noise.Frame{Type: noise.FrameData, Payload: ct})
	if err != nil {
		t.Fatal(err)
	}
	if err := conn.WriteMessage(websocket.TextMessage, []byte(enc)); err != nil {
		t.Fatal(err)
	}
	_, rawR, err := conn.ReadMessage()
	if err != nil {
		t.Fatal(err)
	}
	frR, err := noise.DecodeFrame(string(rawR))
	if err != nil {
		t.Fatal(err)
	}
	plain, err := initSess.Decrypt(frR.Payload)
	if err != nil {
		t.Fatal(err)
	}
	var reply map[string]any
	if err := json.Unmarshal(plain, &reply); err != nil {
		t.Fatal(err)
	}
	if reply["op"] != "result" {
		t.Fatalf("reply=%v", reply)
	}
}

func TestReconnectUnknownPeerNack(t *testing.T) {
	root := t.TempDir()
	nodeID, err := noise.LoadOrCreate(root + "/node.json")
	if err != nil {
		t.Fatal(err)
	}
	clientID, err := noise.LoadOrCreate(root + "/client.json")
	if err != nil {
		t.Fatal(err)
	}
	st, err := store.Open(root+"/data", nodeID.Fingerprint())
	if err != nil {
		t.Fatal(err)
	}
	peers := NewStore(root)
	srv := &Server{
		Store:      st,
		Hub:        NewPairingHub(nodeID, peers, "node"),
		Peers:      peers,
		Identity:   nodeID,
		DeviceName: "node",
	}
	hs := httptest.NewServer(http.HandlerFunc(srv.HandleWS))
	defer hs.Close()

	wsURL := "ws" + strings.TrimPrefix(hs.URL, "http") + "/peer/ws"
	conn, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()

	initSess, err := noise.NewInitiator(clientID, nodeID.PublicKey)
	if err != nil {
		t.Fatal(err)
	}
	msg1, err := initSess.WriteHandshake1([]byte(`{"type":"reconnect"}`))
	if err != nil {
		t.Fatal(err)
	}
	frame1, _ := noise.EncodeFrame(noise.Frame{Type: noise.FrameHS, Payload: msg1})
	_ = conn.WriteMessage(websocket.TextMessage, []byte(frame1))

	_ = conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	_, raw2, err := conn.ReadMessage()
	if err != nil {
		t.Fatal(err)
	}
	fr2, err := noise.DecodeFrame(string(raw2))
	if err != nil {
		t.Fatal(err)
	}
	ackPayload, err := initSess.ReadHandshake2(fr2.Payload)
	if err != nil {
		t.Fatal(err)
	}
	var ack map[string]any
	_ = json.Unmarshal(ackPayload, &ack)
	if ack["type"] != "reconnect_nack" {
		t.Fatalf("expected nack, got %v", ack)
	}
}
