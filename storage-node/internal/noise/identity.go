package noise

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"

	flynn "github.com/flynn/noise"
)

// Identity is a long-term X25519 static keypair (aligned with Dart NoiseIdentity).
type Identity struct {
	PublicKey  []byte `json:"public_key_b64"`  // stored as base64 in file; decoded in memory
	PrivateKey []byte `json:"private_key_b64"`
	CreatedAt  int64  `json:"created_at_ms"`
}

type identityFile struct {
	PublicKeyB64  string `json:"public_key_b64"`
	PrivateKeyB64 string `json:"private_key_b64"`
	CreatedAtMs   int64  `json:"created_at_ms"`
}

// Fingerprint returns first 8 bytes of sha256(pub) as 16 hex (Dart fingerprintHex / device_id).
func (id *Identity) Fingerprint() string {
	sum := sha256.Sum256(id.PublicKey)
	return hex.EncodeToString(sum[:8])
}

func (id *Identity) DHKey() flynn.DHKey {
	return flynn.DHKey{Private: id.PrivateKey, Public: id.PublicKey}
}

func (id *Identity) PublicKeyBase64() string {
	return base64.StdEncoding.EncodeToString(id.PublicKey)
}

// LoadOrCreate loads identity from path or generates a new one.
func LoadOrCreate(path string) (*Identity, error) {
	raw, err := os.ReadFile(path)
	if err == nil {
		var f identityFile
		if err := json.Unmarshal(raw, &f); err != nil {
			return nil, fmt.Errorf("corrupt noise identity: %w", err)
		}
		pub, err := base64.StdEncoding.DecodeString(f.PublicKeyB64)
		if err != nil || len(pub) != 32 {
			return nil, fmt.Errorf("bad public key")
		}
		priv, err := base64.StdEncoding.DecodeString(f.PrivateKeyB64)
		if err != nil || len(priv) != 32 {
			return nil, fmt.Errorf("bad private key")
		}
		return &Identity{PublicKey: pub, PrivateKey: priv, CreatedAt: f.CreatedAtMs}, nil
	}
	if !os.IsNotExist(err) {
		return nil, err
	}

	kp, err := flynn.DH25519.GenerateKeypair(rand.Reader)
	if err != nil {
		return nil, err
	}
	id := &Identity{
		PublicKey:  append([]byte(nil), kp.Public...),
		PrivateKey: append([]byte(nil), kp.Private...),
		CreatedAt:  nowMs(),
	}
	if err := id.Save(path); err != nil {
		return nil, err
	}
	return id, nil
}

func (id *Identity) Save(path string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	f := identityFile{
		PublicKeyB64:  base64.StdEncoding.EncodeToString(id.PublicKey),
		PrivateKeyB64: base64.StdEncoding.EncodeToString(id.PrivateKey),
		CreatedAtMs:   id.CreatedAt,
	}
	raw, err := json.MarshalIndent(f, "", "  ")
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, raw, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}
