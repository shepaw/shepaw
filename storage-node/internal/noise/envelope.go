package noise

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"strings"
	"time"
)

const ProtocolVersion = 2

type FrameType string

const (
	FrameHS   FrameType = "hs"
	FrameData FrameType = "data"
	FrameErr  FrameType = "err"
)

type Frame struct {
	Type    FrameType
	Payload []byte
}

func EncodeFrame(f Frame) (string, error) {
	obj := map[string]any{
		"v": ProtocolVersion,
		"t": string(f.Type),
		"p": toBase64URL(f.Payload),
	}
	raw, err := json.Marshal(obj)
	return string(raw), err
}

func DecodeFrame(raw string) (Frame, error) {
	var obj struct {
		V int    `json:"v"`
		T string `json:"t"`
		P string `json:"p"`
	}
	if err := json.Unmarshal([]byte(raw), &obj); err != nil {
		return Frame{}, err
	}
	if obj.V != ProtocolVersion {
		return Frame{}, fmt.Errorf("unsupported version %d", obj.V)
	}
	payload, err := fromBase64URL(obj.P)
	if err != nil {
		return Frame{}, err
	}
	switch FrameType(obj.T) {
	case FrameHS, FrameData, FrameErr:
		return Frame{Type: FrameType(obj.T), Payload: payload}, nil
	default:
		return Frame{}, fmt.Errorf("unsupported type %s", obj.T)
	}
}

func toBase64URL(b []byte) string {
	return strings.TrimRight(base64.URLEncoding.EncodeToString(b), "=")
}

func fromBase64URL(s string) ([]byte, error) {
	pad := (4 - len(s)%4) % 4
	s += strings.Repeat("=", pad)
	return base64.URLEncoding.DecodeString(s)
}

func nowMs() int64 { return time.Now().UnixMilli() }
