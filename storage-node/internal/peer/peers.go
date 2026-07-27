package peer

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/json"
	"fmt"
	"math/big"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// Peer is a paired owner device.
type Peer struct {
	Fingerprint string `json:"fingerprint"`
	PublicKeyB64 string `json:"public_key_b64"`
	DeviceName  string `json:"device_name"`
	PeerID      string `json:"peer_id"`
	TrustLevel  string `json:"trust_level"`
	PairedAtMs  int64  `json:"paired_at_ms"`
}

type Store struct {
	path string
	mu   sync.Mutex
}

func NewStore(root string) *Store {
	return &Store{path: filepath.Join(root, ".system", "paired_peers.json")}
}

func (s *Store) List() ([]Peer, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.load()
}

func (s *Store) Upsert(p Peer) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	peers, err := s.load()
	if err != nil {
		return err
	}
	out := make([]Peer, 0, len(peers)+1)
	for _, x := range peers {
		if x.Fingerprint != p.Fingerprint {
			out = append(out, x)
		}
	}
	out = append(out, p)
	return s.save(out)
}

func (s *Store) Get(fp string) (*Peer, error) {
	peers, err := s.List()
	if err != nil {
		return nil, err
	}
	for _, p := range peers {
		if p.Fingerprint == fp {
			cp := p
			return &cp, nil
		}
	}
	return nil, nil
}

func (s *Store) load() ([]Peer, error) {
	raw, err := os.ReadFile(s.path)
	if err != nil {
		if os.IsNotExist(err) {
			return []Peer{}, nil
		}
		return nil, err
	}
	var peers []Peer
	if err := json.Unmarshal(raw, &peers); err != nil {
		return nil, err
	}
	if peers == nil {
		peers = []Peer{}
	}
	return peers, nil
}

func (s *Store) save(peers []Peer) error {
	if err := os.MkdirAll(filepath.Dir(s.path), 0o755); err != nil {
		return err
	}
	raw, err := json.MarshalIndent(peers, "", "  ")
	if err != nil {
		return err
	}
	tmp := s.path + ".tmp"
	if err := os.WriteFile(tmp, raw, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, s.path)
}

const pairingAlphabet = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"

func GeneratePairingCode() (string, error) {
	out := make([]byte, 8)
	for i := range out {
		n, err := rand.Int(rand.Reader, big.NewInt(int64(len(pairingAlphabet))))
		if err != nil {
			return "", err
		}
		out[i] = pairingAlphabet[n.Int64()]
	}
	return string(out), nil
}

func ConstantTimeEqual(a, b string) bool {
	if len(a) != len(b) {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(a), []byte(b)) == 1
}

func NewPeerID() string {
	var b [8]byte
	_, _ = rand.Read(b[:])
	return fmt.Sprintf("peer-%x", b)
}

func NowMs() int64 { return time.Now().UnixMilli() }
