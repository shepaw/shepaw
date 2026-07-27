package store

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
)

// deviceCursors persists master-side applied_seq per device
// (aligned with Dart DeviceCursorStore → .system/device_cursors.json).
type deviceCursors struct {
	path string
	mu   sync.Mutex
}

func newDeviceCursors(root string) *deviceCursors {
	return &deviceCursors{path: filepath.Join(root, ".system", "device_cursors.json")}
}

func (c *deviceCursors) appliedSeq(deviceID string) (int64, error) {
	m, err := c.all()
	if err != nil {
		return 0, err
	}
	return m[deviceID], nil
}

func (c *deviceCursors) all() (map[string]int64, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.loadLocked()
}

// advance sets applied_seq = max(current, upto). Returns the new value.
func (c *deviceCursors) advance(deviceID string, upto int64) (int64, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	m, err := c.loadLocked()
	if err != nil {
		return 0, err
	}
	cur := m[deviceID]
	next := cur
	if upto > cur {
		next = upto
	}
	m[deviceID] = next
	if err := c.saveLocked(m); err != nil {
		return 0, err
	}
	return next, nil
}

func (c *deviceCursors) remove(deviceID string) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	m, err := c.loadLocked()
	if err != nil {
		return err
	}
	if _, ok := m[deviceID]; !ok {
		return nil
	}
	delete(m, deviceID)
	return c.saveLocked(m)
}

func (c *deviceCursors) loadLocked() (map[string]int64, error) {
	raw, err := os.ReadFile(c.path)
	if err != nil {
		if os.IsNotExist(err) {
			return map[string]int64{}, nil
		}
		return nil, err
	}
	var decoded map[string]any
	if err := json.Unmarshal(raw, &decoded); err != nil {
		return nil, err
	}
	out := make(map[string]int64, len(decoded))
	for k, v := range decoded {
		out[k] = anyToInt64(v)
	}
	return out, nil
}

func (c *deviceCursors) saveLocked(m map[string]int64) error {
	if err := os.MkdirAll(filepath.Dir(c.path), 0o755); err != nil {
		return err
	}
	raw, err := json.Marshal(m)
	if err != nil {
		return err
	}
	tmp := c.path + ".tmp"
	if err := os.WriteFile(tmp, raw, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, c.path)
}

func anyToInt64(v any) int64 {
	switch n := v.(type) {
	case float64:
		return int64(n)
	case int64:
		return n
	case int:
		return int64(n)
	case json.Number:
		i, _ := n.Int64()
		return i
	default:
		return 0
	}
}

func payloadInt64(payload map[string]any, key string) (int64, bool) {
	if payload == nil {
		return 0, false
	}
	v, ok := payload[key]
	if !ok || v == nil {
		return 0, false
	}
	return anyToInt64(v), true
}
