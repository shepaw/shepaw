package peer

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/url"
	"sync"

	"github.com/shepaw/storage-node/internal/noise"
)

// PairingRequest matches Dart PairingRequest JSON.
type PairingRequest struct {
	PairingCode     string `json:"pairing_code"`
	DeviceName      string `json:"device_name"`
	DeviceID        string `json:"device_id"`
	ChannelEndpoint string `json:"channel_endpoint,omitempty"`
	LocalEndpoint   string `json:"local_endpoint,omitempty"`
	Timestamp       int64  `json:"timestamp"`
}

// PairingResponse matches Dart PairingResponse JSON.
type PairingResponse struct {
	Accepted        bool   `json:"accepted"`
	DeviceName      string `json:"device_name"`
	DeviceID        string `json:"device_id"`
	PeerID          string `json:"peer_id"`
	ChannelEndpoint string `json:"channel_endpoint,omitempty"`
	LocalEndpoint   string `json:"local_endpoint,omitempty"`
	RejectReason    string `json:"reject_reason,omitempty"`
}

// PendingRequest is shown on admin for approval.
type PendingRequest struct {
	DeviceName  string `json:"device_name"`
	DeviceID    string `json:"device_id"`
	Fingerprint string `json:"fingerprint"`
	SessionID   string `json:"session_id"`
}

// PairingHub manages active responder pairing sessions.
type PairingHub struct {
	mu       sync.Mutex
	identity *noise.Identity
	peers    *Store
	deviceName string

	code      string
	active    *activePairing
	pending   *PendingRequest
	waitAccept chan bool // true=accept
}

type activePairing struct {
	session   *noise.Session
	peerPub   []byte
	request   PairingRequest
	sessionID string
}

func NewPairingHub(id *noise.Identity, peers *Store, deviceName string) *PairingHub {
	return &PairingHub{
		identity:   id,
		peers:      peers,
		deviceName: deviceName,
	}
}

func (h *PairingHub) Start() (qr string, code string, err error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	code, err = GeneratePairingCode()
	if err != nil {
		return "", "", err
	}
	h.code = code
	h.pending = nil
	h.active = nil
	h.waitAccept = nil
	return "", code, nil
}

func (h *PairingHub) Code() string {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.code
}

func (h *PairingHub) Pending() *PendingRequest {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.pending == nil {
		return nil
	}
	cp := *h.pending
	return &cp
}

func (h *PairingHub) Decide(accept bool) error {
	h.mu.Lock()
	ch := h.waitAccept
	h.mu.Unlock()
	if ch == nil {
		return fmt.Errorf("no pending pairing")
	}
	select {
	case ch <- accept:
		return nil
	default:
		return fmt.Errorf("decision already sent")
	}
}

// EncodeQR builds shepaw://peer?... matching Dart PeerPairingInfo.encode.
func EncodeQR(localEndpoint, code, fingerprint string, publicKey []byte) string {
	pk := noiseToBase64URL(publicKey)
	q := url.Values{}
	q.Set("local", localEndpoint)
	q.Set("code", code)
	return fmt.Sprintf("shepaw://peer?%s#fp=%s&pk=%s", q.Encode(), fingerprint, pk)
}

func noiseToBase64URL(b []byte) string {
	return base64.RawURLEncoding.EncodeToString(b)
}

func FingerprintFromKey(pub []byte) string {
	sum := sha256.Sum256(pub)
	return hex.EncodeToString(sum[:8])
}

func (h *PairingHub) beginAcceptWait() chan bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.waitAccept = make(chan bool, 1)
	return h.waitAccept
}

func (h *PairingHub) setPending(p *PendingRequest, a *activePairing) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.pending = p
	h.active = a
}

func (h *PairingHub) clearPairing() {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.pending = nil
	h.active = nil
	h.waitAccept = nil
	h.code = ""
}

func parsePairingRequest(b []byte) (PairingRequest, error) {
	var r PairingRequest
	err := json.Unmarshal(b, &r)
	return r, err
}

func encodePairingResponse(r PairingResponse) ([]byte, error) {
	return json.Marshal(r)
}
