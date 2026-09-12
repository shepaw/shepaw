package protocol

import (
	"bytes"
	"testing"
)

func TestStoreBinRoundTrip(t *testing.T) {
	in := StoreBinChunk{
		ReqID:    "r-abc",
		Offset:   262144,
		FileSize: 1000000,
		EOF:      false,
		Data:     []byte{1, 2, 3, 4},
	}
	raw, err := EncodeStoreBin(in)
	if err != nil {
		t.Fatal(err)
	}
	if !LooksLikeStoreBin(raw) {
		t.Fatal("magic")
	}
	out, err := DecodeStoreBin(raw)
	if err != nil {
		t.Fatal(err)
	}
	if out.ReqID != in.ReqID || out.Offset != in.Offset || out.FileSize != in.FileSize || out.EOF != in.EOF {
		t.Fatalf("header %+v", out)
	}
	if !bytes.Equal(out.Data, in.Data) {
		t.Fatalf("data %v", out.Data)
	}
}

func TestWantsBinaryRead(t *testing.T) {
	if !WantsBinaryRead("read", map[string]any{"encoding": "bin"}) {
		t.Fatal("expected bin")
	}
	if WantsBinaryRead("read", map[string]any{}) {
		t.Fatal("default is json")
	}
	if WantsBinaryRead("meta", map[string]any{"encoding": "bin"}) {
		t.Fatal("meta is not a read")
	}
}
