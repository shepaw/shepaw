package peer

import (
	"sync"
	"testing"

	"github.com/shepaw/storage-node/internal/noise"
)

func TestEncryptUnderWriteMuPreservesDecryptOrder(t *testing.T) {
	root := t.TempDir()
	a, err := noise.LoadOrCreate(root + "/a.json")
	if err != nil {
		t.Fatal(err)
	}
	b, err := noise.LoadOrCreate(root + "/b.json")
	if err != nil {
		t.Fatal(err)
	}
	initSess, err := noise.NewInitiator(a, b.PublicKey)
	if err != nil {
		t.Fatal(err)
	}
	respSess, err := noise.NewResponder(b)
	if err != nil {
		t.Fatal(err)
	}
	msg1, err := initSess.WriteHandshake1([]byte(`{"type":"reconnect"}`))
	if err != nil {
		t.Fatal(err)
	}
	_, _, err = respSess.ReadHandshake1(msg1)
	if err != nil {
		t.Fatal(err)
	}
	msg2, err := respSess.WriteHandshake2([]byte(`{"type":"reconnect_ack"}`))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := initSess.ReadHandshake2(msg2); err != nil {
		t.Fatal(err)
	}

	var writeMu sync.Mutex
	ciphertexts := make([][]byte, 0, 32)
	var wg sync.WaitGroup
	for i := 0; i < 32; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			p := []byte{byte(i), 'o', 'k'}
			writeMu.Lock()
			ct, err := initSess.Encrypt(p)
			if err == nil {
				ciphertexts = append(ciphertexts, ct)
			}
			writeMu.Unlock()
			if err != nil {
				t.Errorf("encrypt: %v", err)
			}
		}(i)
	}
	wg.Wait()
	if len(ciphertexts) != 32 {
		t.Fatalf("got %d ciphertexts", len(ciphertexts))
	}
	for i, ct := range ciphertexts {
		plain, err := respSess.Decrypt(ct)
		if err != nil {
			t.Fatalf("decrypt %d: %v", i, err)
		}
		if len(plain) != 3 || plain[1] != 'o' {
			t.Fatalf("plain %d=%v", i, plain)
		}
	}
}
