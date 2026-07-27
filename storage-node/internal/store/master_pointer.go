package store

import (
	"encoding/json"
	"os"
	"path/filepath"

	"github.com/shepaw/storage-node/internal/protocol"
)

type masterPointer struct {
	Master string `json:"master"`
	Epoch  int64  `json:"epoch"`
}

func (l *Local) pointerPath() string {
	return filepath.Join(l.Root, ".system", "master_pointer.json")
}

func (l *Local) loadPointer() (masterPointer, error) {
	raw, err := os.ReadFile(l.pointerPath())
	if err != nil {
		if os.IsNotExist(err) {
			return masterPointer{Master: l.DeviceID, Epoch: 0}, nil
		}
		return masterPointer{}, err
	}
	var p masterPointer
	if err := json.Unmarshal(raw, &p); err != nil {
		return masterPointer{}, err
	}
	if !protocol.IsValidDeviceID(p.Master) {
		p.Master = l.DeviceID
	}
	return p, nil
}

func (l *Local) savePointer(p masterPointer) error {
	if err := os.MkdirAll(filepath.Dir(l.pointerPath()), 0o755); err != nil {
		return err
	}
	raw, err := json.MarshalIndent(p, "", "  ")
	if err != nil {
		return err
	}
	tmp := l.pointerPath() + ".tmp"
	if err := os.WriteFile(tmp, raw, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, l.pointerPath())
}

func (l *Local) masterPointerQuery() (map[string]any, error) {
	p, err := l.loadPointer()
	if err != nil {
		return nil, err
	}
	return map[string]any{"master": p.Master, "epoch": p.Epoch}, nil
}

// masterPointerApply applies an inbound pointer (broadcast or RPC).
// Only advances when epoch is newer (or same epoch with different master).
func (l *Local) masterPointerApply(frame protocol.Frame) (map[string]any, error) {
	master, _ := frame.Payload["master"].(string)
	epoch := anyToInt64(frame.Payload["epoch"])
	if !protocol.IsValidDeviceID(master) || epoch <= 0 {
		return nil, &OpError{Code: "bad_op", Msg: "invalid master pointer"}
	}
	cur, err := l.loadPointer()
	if err != nil {
		return nil, err
	}
	if epoch < cur.Epoch {
		return map[string]any{"applied": false, "reason": "stale"}, nil
	}
	if epoch == cur.Epoch && cur.Master == master {
		return map[string]any{"applied": false, "reason": "unchanged"}, nil
	}
	next := masterPointer{Master: master, Epoch: epoch}
	if err := l.savePointer(next); err != nil {
		return nil, err
	}
	return map[string]any{"applied": true, "master": master, "epoch": epoch}, nil
}
