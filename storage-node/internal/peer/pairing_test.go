package peer

import (
	"net/url"
	"strings"
	"testing"
)

func TestEncodeQRIncludesChannel(t *testing.T) {
	pub := make([]byte, 32)
	for i := range pub {
		pub[i] = byte(i)
	}
	local := "ws://192.168.1.10:8787/peer/ws"
	channel := "wss://channel.example/proxy/node/peer/ws"
	qr := EncodeQR(local, channel, "ABCD2345", "deadbeefcafebabe", pub)
	u, err := url.Parse(qr)
	if err != nil {
		t.Fatal(err)
	}
	if u.Scheme != "shepaw" || u.Host != "peer" {
		t.Fatalf("uri=%s", qr)
	}
	q := u.Query()
	if q.Get("local") != local {
		t.Fatalf("local=%q", q.Get("local"))
	}
	if q.Get("channel") != channel {
		t.Fatalf("channel=%q", q.Get("channel"))
	}
	if q.Get("code") != "ABCD2345" {
		t.Fatalf("code=%q", q.Get("code"))
	}
	if !strings.Contains(u.Fragment, "fp=deadbeefcafebabe") {
		t.Fatalf("fragment=%q", u.Fragment)
	}
}

func TestEncodeQRLocalOnly(t *testing.T) {
	pub := make([]byte, 32)
	qr := EncodeQR("ws://127.0.0.1:8787/peer/ws", "", "CODE1234", "aabbccddeeff0011", pub)
	u, err := url.Parse(qr)
	if err != nil {
		t.Fatal(err)
	}
	if u.Query().Get("channel") != "" {
		t.Fatalf("unexpected channel in %s", qr)
	}
	if u.Query().Get("local") == "" {
		t.Fatal("missing local")
	}
}

func TestAdvertiseLocalWSFixedHost(t *testing.T) {
	got := AdvertiseLocalWS("10.0.0.5:9000")
	if got != "ws://10.0.0.5:9000/peer/ws" {
		t.Fatalf("got %s", got)
	}
}
