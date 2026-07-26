// Package store implements a filesystem-backed store.* root for the headless node.
package store

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"hash"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/shepaw/storage-node/internal/protocol"
)

const maxChunk = 65536

type Local struct {
	Root     string
	DeviceID string
	mu       sync.Mutex
	uploads  map[string]*upload
}

type upload struct {
	Space string
	Path  string
	Tmp   string
	Size  int64
	Hash  hashWriter
}

type hashWriter struct {
	h hash.Hash
	n int64
}

func newHashWriter() hashWriter {
	return hashWriter{h: sha256.New()}
}

func (h *hashWriter) Write(p []byte) (int, error) {
	n, err := h.h.Write(p)
	h.n += int64(n)
	return n, err
}

func (h *hashWriter) Sum() string {
	return hex.EncodeToString(h.h.Sum(nil))
}

func Open(root, deviceID string) (*Local, error) {
	if !protocol.IsValidDeviceID(deviceID) {
		return nil, fmt.Errorf("bad device id")
	}
	if err := os.MkdirAll(root, 0o755); err != nil {
		return nil, err
	}
	for _, sp := range []string{"artifacts", "files", "attachments", "backups"} {
		if err := os.MkdirAll(filepath.Join(root, deviceID, sp), 0o755); err != nil {
			return nil, err
		}
	}
	if err := os.MkdirAll(filepath.Join(root, ".recycle"), 0o755); err != nil {
		return nil, err
	}
	return &Local{Root: root, DeviceID: deviceID, uploads: map[string]*upload{}}, nil
}

func (l *Local) Handle(frame protocol.Frame, caller, trust string, loopback bool) (map[string]any, error) {
	if v := protocol.CheckACL(frame, caller, trust, loopback); v != protocol.Allow {
		return nil, &OpError{Code: aclCode(v), Msg: string(v)}
	}
	switch frame.Op {
	case "list":
		return l.list(frame, caller)
	case "meta":
		return l.meta(frame, caller)
	case "read":
		return l.read(frame, caller)
	case "write.begin":
		return l.writeBegin(frame, caller)
	case "write.chunk":
		return l.writeChunk(frame)
	case "commit":
		return l.commit(frame)
	case "delete":
		return l.delete(frame, caller)
	case "stats":
		return l.stats()
	case "recycle.list":
		return l.recycleList()
	case "recycle.empty":
		return l.recycleEmpty()
	default:
		return nil, &OpError{Code: "bad_op", Msg: frame.Op}
	}
}

type OpError struct {
	Code string
	Msg  string
}

func (e *OpError) Error() string { return e.Code + ": " + e.Msg }

func aclCode(v protocol.AclVerdict) string {
	switch v {
	case protocol.DenyUntrusted:
		return "untrusted"
	case protocol.DenyAcl:
		return "acl_denied"
	case protocol.DenyBadOp:
		return "bad_op"
	case protocol.DenyBadPath:
		return "bad_path"
	default:
		return "internal"
	}
}

func (l *Local) resolve(space, device, rel string) (string, error) {
	if device == "" {
		device = l.DeviceID
	}
	base := filepath.Join(l.Root, device, space)
	if rel == "" || rel == "/" {
		return base, nil
	}
	norm, err := protocol.NormalizePath(rel)
	if err != nil {
		return "", &OpError{Code: "bad_path", Msg: err.Error()}
	}
	full := filepath.Join(base, filepath.FromSlash(norm))
	if !strings.HasPrefix(full, base+string(os.PathSeparator)) && full != base {
		return "", &OpError{Code: "bad_path", Msg: "escape"}
	}
	return full, nil
}

func (l *Local) list(frame protocol.Frame, caller string) (map[string]any, error) {
	device := frame.Device()
	if device == "" {
		device = caller
	}
	path, _ := frame.Payload["path"].(string)
	dir, err := l.resolve(frame.Space(), device, path)
	if err != nil {
		return nil, err
	}
	entries := []map[string]any{}
	_ = filepath.Walk(dir, func(p string, info os.FileInfo, err error) error {
		if err != nil {
			return nil
		}
		if info.IsDir() {
			name := info.Name()
			if strings.HasPrefix(name, ".") || name == ".staging" {
				return filepath.SkipDir
			}
			return nil
		}
		if strings.HasPrefix(info.Name(), ".") {
			return nil
		}
		rel, _ := filepath.Rel(dir, p)
		rel = filepath.ToSlash(rel)
		sum, size := fileSHA(p)
		entries = append(entries, map[string]any{
			"path": rel, "size": size, "sha256": sum, "mtime": info.ModTime().UnixMilli(),
		})
		return nil
	})
	return map[string]any{"entries": entries}, nil
}

func (l *Local) meta(frame protocol.Frame, caller string) (map[string]any, error) {
	device := frame.Device()
	if device == "" {
		device = caller
	}
	path, _ := frame.Payload["path"].(string)
	full, err := l.resolve(frame.Space(), device, path)
	if err != nil {
		return nil, err
	}
	st, err := os.Stat(full)
	if err != nil {
		return nil, &OpError{Code: "not_found", Msg: err.Error()}
	}
	if st.IsDir() {
		return map[string]any{"kind": "dir"}, nil
	}
	sum, size := fileSHA(full)
	return map[string]any{"kind": "file", "size": size, "sha256": sum, "mtime": st.ModTime().UnixMilli()}, nil
}

func (l *Local) read(frame protocol.Frame, caller string) (map[string]any, error) {
	device := frame.Device()
	if device == "" {
		device = caller
	}
	path, _ := frame.Payload["path"].(string)
	full, err := l.resolve(frame.Space(), device, path)
	if err != nil {
		return nil, err
	}
	f, err := os.Open(full)
	if err != nil {
		return nil, &OpError{Code: "not_found", Msg: err.Error()}
	}
	defer f.Close()
	offset := int64(num(frame.Payload["offset"]))
	length := int64(num(frame.Payload["length"]))
	if length <= 0 || length > maxChunk {
		length = maxChunk
	}
	if _, err := f.Seek(offset, io.SeekStart); err != nil {
		return map[string]any{"data": "", "size": 0, "eof": true}, nil
	}
	buf := make([]byte, length)
	n, err := io.ReadFull(f, buf)
	if err != nil && err != io.EOF && err != io.ErrUnexpectedEOF {
		n = 0
	}
	eof := n < int(length)
	return map[string]any{
		"data": base64.StdEncoding.EncodeToString(buf[:n]),
		"size": n,
		"eof":  eof,
	}, nil
}

func (l *Local) writeBegin(frame protocol.Frame, caller string) (map[string]any, error) {
	path, _ := frame.Payload["path"].(string)
	norm, err := protocol.NormalizePath(path)
	if err != nil {
		return nil, &OpError{Code: "bad_path", Msg: err.Error()}
	}
	id := fmt.Sprintf("%d", time.Now().UnixNano())
	staging := filepath.Join(l.Root, caller, frame.Space(), ".staging", id)
	if err := os.MkdirAll(staging, 0o755); err != nil {
		return nil, err
	}
	tmp := filepath.Join(staging, "blob")
	l.mu.Lock()
	l.uploads[id] = &upload{Space: frame.Space(), Path: norm, Tmp: tmp, Hash: newHashWriter()}
	l.mu.Unlock()
	return map[string]any{"upload_id": id}, nil
}

func (l *Local) writeChunk(frame protocol.Frame) (map[string]any, error) {
	id, _ := frame.Payload["upload_id"].(string)
	dataB64, _ := frame.Payload["data"].(string)
	raw, err := base64.StdEncoding.DecodeString(dataB64)
	if err != nil {
		return nil, &OpError{Code: "bad_op", Msg: "bad base64"}
	}
	if len(raw) > maxChunk {
		return nil, &OpError{Code: "bad_op", Msg: "chunk too large"}
	}
	l.mu.Lock()
	u := l.uploads[id]
	l.mu.Unlock()
	if u == nil {
		return nil, &OpError{Code: "staging_state", Msg: "unknown upload"}
	}
	f, err := os.OpenFile(u.Tmp, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	if _, err := f.Write(raw); err != nil {
		return nil, err
	}
	_, _ = u.Hash.Write(raw)
	u.Size += int64(len(raw))
	return map[string]any{"accepted": len(raw)}, nil
}

func (l *Local) commit(frame protocol.Frame) (map[string]any, error) {
	ids, _ := frame.Payload["upload_ids"].([]any)
	if ids == nil {
		if one, ok := frame.Payload["upload_id"].(string); ok {
			ids = []any{one}
		}
	}
	expected := map[string]string{}
	if arr, ok := frame.Payload["files"].([]any); ok {
		for _, it := range arr {
			m, _ := it.(map[string]any)
			if m == nil {
				continue
			}
			id, _ := m["upload_id"].(string)
			sum, _ := m["sha256"].(string)
			expected[id] = sum
		}
	}
	// Validate all first (all-or-nothing).
	type pending struct {
		id  string
		u   *upload
		sum string
	}
	batch := make([]pending, 0, len(ids))
	for _, rawID := range ids {
		id, _ := rawID.(string)
		l.mu.Lock()
		u := l.uploads[id]
		l.mu.Unlock()
		if u == nil {
			return nil, &OpError{Code: "staging_state", Msg: "unknown " + id}
		}
		sum := u.Hash.Sum()
		if want, ok := expected[id]; ok && want != "" && want != sum {
			return nil, &OpError{Code: "hash_mismatch", Msg: id}
		}
		batch = append(batch, pending{id: id, u: u, sum: sum})
	}
	committed := []map[string]any{}
	for _, p := range batch {
		dest := filepath.Join(l.Root, l.DeviceID, p.u.Space, filepath.FromSlash(p.u.Path))
		if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
			return nil, err
		}
		if err := os.Rename(p.u.Tmp, dest); err != nil {
			return nil, err
		}
		_ = os.RemoveAll(filepath.Dir(p.u.Tmp))
		l.mu.Lock()
		delete(l.uploads, p.id)
		l.mu.Unlock()
		committed = append(committed, map[string]any{"path": p.u.Path, "size": p.u.Size, "sha256": p.sum})
	}
	return map[string]any{"files": committed}, nil
}

func (l *Local) delete(frame protocol.Frame, caller string) (map[string]any, error) {
	device := frame.Device()
	if device == "" {
		device = caller
	}
	path, _ := frame.Payload["path"].(string)
	full, err := l.resolve(frame.Space(), device, path)
	if err != nil {
		return nil, err
	}
	if _, err := os.Stat(full); err != nil {
		return nil, &OpError{Code: "not_found", Msg: err.Error()}
	}
	recycle := filepath.Join(l.Root, ".recycle", fmt.Sprintf("%d-%s", time.Now().UnixNano(), filepath.Base(full)))
	if err := os.Rename(full, recycle); err != nil {
		return nil, err
	}
	meta, _ := json.Marshal(map[string]any{"from": full, "at": time.Now().UnixMilli()})
	_ = os.WriteFile(recycle+".meta.json", meta, 0o644)
	return map[string]any{"ok": true}, nil
}

func (l *Local) stats() (map[string]any, error) {
	var total int64
	_ = filepath.Walk(l.Root, func(_ string, info os.FileInfo, err error) error {
		if err == nil && info != nil && !info.IsDir() {
			total += info.Size()
		}
		return nil
	})
	return map[string]any{"bytes": total, "device": l.DeviceID}, nil
}

func (l *Local) recycleList() (map[string]any, error) {
	dir := filepath.Join(l.Root, ".recycle")
	ents, _ := os.ReadDir(dir)
	out := []map[string]any{}
	for _, e := range ents {
		if strings.HasSuffix(e.Name(), ".meta.json") {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		out = append(out, map[string]any{"name": e.Name(), "size": info.Size()})
	}
	return map[string]any{"entries": out}, nil
}

func (l *Local) recycleEmpty() (map[string]any, error) {
	dir := filepath.Join(l.Root, ".recycle")
	_ = os.RemoveAll(dir)
	_ = os.MkdirAll(dir, 0o755)
	return map[string]any{"ok": true}, nil
}

func fileSHA(path string) (string, int64) {
	f, err := os.Open(path)
	if err != nil {
		return "", 0
	}
	defer f.Close()
	h := sha256.New()
	n, _ := io.Copy(h, f)
	return hex.EncodeToString(h.Sum(nil)), n
}

func num(v any) float64 {
	switch t := v.(type) {
	case float64:
		return t
	case int:
		return float64(t)
	case int64:
		return float64(t)
	case json.Number:
		f, _ := t.Float64()
		return f
	default:
		return 0
	}
}
