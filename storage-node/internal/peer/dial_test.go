package peer

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/shepaw/storage-node/internal/noise"
	"github.com/shepaw/storage-node/internal/protocol"
	"github.com/shepaw/storage-node/internal/store"
)

func TestDialReconnectEnsure(t *testing.T) {
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
		PeerID:       "peer-1",
		TrustLevel:   protocol.TrustOwner,
		PairedAtMs:   NowMs(),
	}); err != nil {
		t.Fatal(err)
	}
	// Reverse: client dials INTO node. So node is the server; dialer is client identity
	// dialing node's endpoint. Peers on dialer side must know node's key+endpoint.
	sessions := NewSessionRegistry()
	srv := &Server{
		Store:      st,
		Hub:        NewPairingHub(nodeID, peers, "node"),
		Peers:      peers,
		Sessions:   sessions,
		Identity:   nodeID,
		DeviceName: "node",
	}
	hs := httptest.NewServer(http.HandlerFunc(srv.HandleWS))
	defer hs.Close()
	wsURL := "ws" + strings.TrimPrefix(hs.URL, "http") + "/peer/ws"

	// Dialer identity = client; target = node (paired on dialer's peer store)
	dialRoot := t.TempDir()
	dialPeers := NewStore(dialRoot)
	if err := dialPeers.Upsert(Peer{
		Fingerprint:     nodeID.Fingerprint(),
		PublicKeyB64:    nodeID.PublicKeyBase64(),
		DeviceName:      "node",
		PeerID:          "peer-node",
		TrustLevel:      protocol.TrustOwner,
		PairedAtMs:      NowMs(),
		LocalEndpoint:   wsURL,
		ChannelEndpoint: "",
	}); err != nil {
		t.Fatal(err)
	}
	// Server must know client for reconnect_ack
	if err := peers.Upsert(Peer{
		Fingerprint:  clientID.Fingerprint(),
		PublicKeyB64: clientID.PublicKeyBase64(),
		DeviceName:   "phone",
		PeerID:       "peer-1",
		TrustLevel:   protocol.TrustOwner,
		PairedAtMs:   NowMs(),
	}); err != nil {
		t.Fatal(err)
	}

	dialSessions := NewSessionRegistry()
	dialer := NewDialer(clientID, dialPeers, dialSessions, "", "")
	if err := dialer.Ensure(nodeID.Fingerprint()); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(2 * time.Second)
	for !dialSessions.Has(nodeID.Fingerprint()) && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	if !dialSessions.Has(nodeID.Fingerprint()) {
		t.Fatal("expected live session after dial")
	}

	// RPC stats via dialed session
	data, err := dialSessions.Call(nodeID.Fingerprint(), "stats", map[string]any{})
	if err != nil {
		t.Fatal(err)
	}
	if data == nil {
		t.Fatal("nil stats")
	}

	dialer.Release(nodeID.Fingerprint())
	deadline = time.Now().Add(2 * time.Second)
	for dialSessions.Has(nodeID.Fingerprint()) && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
}
