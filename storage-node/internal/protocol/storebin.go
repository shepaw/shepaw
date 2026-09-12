package protocol

import (
	"encoding/binary"
	"errors"
	"fmt"
)

const (
	StoreBinMagic0        = 'S'
	StoreBinMagic1        = 'P'
	StoreBinMagic2        = 'B'
	StoreBinMagic3        = '1'
	StoreBinKindReadChunk = 1
	StoreBinMaxReqID      = 255
	StoreBinMaxPayload    = 1024 * 1024
	StoreBinJSONChunk     = 64 * 1024
	StoreBinBinaryChunk   = 256 * 1024
)

var (
	errNotStoreBin = errors.New("not a store binary frame")
	errStoreBin    = errors.New("invalid store binary frame")
)

// StoreBinChunk is the Noise-plaintext body for encoding=bin read replies.
type StoreBinChunk struct {
	ReqID    string
	Offset   uint64
	FileSize uint64
	EOF      bool
	Data     []byte
}

func LooksLikeStoreBin(plain []byte) bool {
	return len(plain) >= 28 &&
		plain[0] == StoreBinMagic0 &&
		plain[1] == StoreBinMagic1 &&
		plain[2] == StoreBinMagic2 &&
		plain[3] == StoreBinMagic3
}

func EncodeStoreBin(c StoreBinChunk) ([]byte, error) {
	req := []byte(c.ReqID)
	if len(req) < 1 || len(req) > StoreBinMaxReqID {
		return nil, fmt.Errorf("req_id length")
	}
	if len(c.Data) > StoreBinMaxPayload {
		return nil, fmt.Errorf("chunk too large")
	}
	out := make([]byte, 27+len(req)+len(c.Data))
	out[0] = StoreBinMagic0
	out[1] = StoreBinMagic1
	out[2] = StoreBinMagic2
	out[3] = StoreBinMagic3
	out[4] = StoreBinKindReadChunk
	out[5] = byte(len(req))
	copy(out[6:], req)
	o := 6 + len(req)
	binary.BigEndian.PutUint64(out[o:], c.Offset)
	o += 8
	binary.BigEndian.PutUint64(out[o:], c.FileSize)
	o += 8
	if c.EOF {
		out[o] = 1
	}
	o++
	binary.BigEndian.PutUint32(out[o:], uint32(len(c.Data)))
	o += 4
	copy(out[o:], c.Data)
	return out, nil
}

func DecodeStoreBin(plain []byte) (StoreBinChunk, error) {
	if !LooksLikeStoreBin(plain) {
		return StoreBinChunk{}, errNotStoreBin
	}
	if plain[4] != StoreBinKindReadChunk {
		return StoreBinChunk{}, errStoreBin
	}
	reqLen := int(plain[5])
	if reqLen < 1 {
		return StoreBinChunk{}, errStoreBin
	}
	o := 6
	if o+reqLen+8+8+1+4 > len(plain) {
		return StoreBinChunk{}, errStoreBin
	}
	reqID := string(plain[o : o+reqLen])
	o += reqLen
	offset := binary.BigEndian.Uint64(plain[o:])
	o += 8
	fileSize := binary.BigEndian.Uint64(plain[o:])
	o += 8
	eof := plain[o]&1 == 1
	o++
	dataLen := int(binary.BigEndian.Uint32(plain[o:]))
	o += 4
	if dataLen > StoreBinMaxPayload || o+dataLen != len(plain) {
		return StoreBinChunk{}, errStoreBin
	}
	data := make([]byte, dataLen)
	copy(data, plain[o:o+dataLen])
	return StoreBinChunk{
		ReqID:    reqID,
		Offset:   offset,
		FileSize: fileSize,
		EOF:      eof,
		Data:     data,
	}, nil
}

func WantsBinaryRead(op string, payload map[string]any) bool {
	if op != "read" && op != "versions.read" {
		return false
	}
	enc, _ := payload["encoding"].(string)
	return enc == "bin"
}
