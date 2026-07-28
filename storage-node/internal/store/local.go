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
	Root       string
	DeviceID   string
	mu         sync.Mutex
	uploads    map[string]*upload
	imports    *importAuth
	cursors    *deviceCursors
	peerRPC    PeerRPC
	peerEnsure PeerEnsure
	seedAuth   map[string]time.Time // caller → expire (migrate seed window)
}

type upload struct {
	Device string
	Space  string
	Path   string
	Tmp    string
	Size   int64
	Hash   hashWriter
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
	return &Local{
		Root:     root,
		DeviceID: deviceID,
		uploads:  map[string]*upload{},
		imports:  newImportAuth(root),
		cursors:  newDeviceCursors(root),
		seedAuth: map[string]time.Time{},
	}, nil
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
		return l.commit(frame, caller)
	case "delete":
		return l.delete(frame, caller)
	case "stats":
		return l.stats()
	case "recycle.list":
		return l.recycleList()
	case "recycle.restore":
		return l.recycleRestore(frame)
	case "recycle.empty":
		return l.recycleEmpty()
	case "import.request":
		return l.importRequest(frame, caller)
	case "import.pending":
		return l.importPending()
	case "import.grant":
		return l.importGrant(frame)
	case "import.reject":
		return l.importReject(frame)
	case "import.grants":
		return l.importGrants(frame)
	case "sync.hello":
		return l.syncHello(caller)
	case "sync.cursors":
		l.authorizeSeed(caller)
		return l.syncCursors()
	case "master.pointer.query":
		return l.masterPointerQuery()
	case "master.pointer":
		return l.masterPointerApply(frame)
	case "master.migrate":
		return l.masterMigrate(frame)
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
	if err := l.requireImportGrant(frame, caller); err != nil {
		return nil, err
	}
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
	if err := l.requireImportGrant(frame, caller); err != nil {
		return nil, err
	}
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
	if err := l.requireImportGrant(frame, caller); err != nil {
		return nil, err
	}
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
	l.uploads[id] = &upload{
		Device: caller,
		Space:  frame.Space(),
		Path:   norm,
		Tmp:    tmp,
		Hash:   newHashWriter(),
	}
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

func (l *Local) commit(frame protocol.Frame, caller string) (map[string]any, error) {
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
	failed := []map[string]any{}
	for _, p := range batch {
		dest := filepath.Join(l.Root, p.u.Device, p.u.Space, filepath.FromSlash(p.u.Path))
		if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
			failed = append(failed, map[string]any{"upload_id": p.id, "error": err.Error()})
			continue
		}
		if err := os.Rename(p.u.Tmp, dest); err != nil {
			failed = append(failed, map[string]any{"upload_id": p.id, "error": err.Error()})
			continue
		}
		_ = os.RemoveAll(filepath.Dir(p.u.Tmp))
		l.mu.Lock()
		delete(l.uploads, p.id)
		l.mu.Unlock()
		committed = append(committed, map[string]any{
			"upload_id": p.id, "path": p.u.Path, "size": p.u.Size, "sha256": p.sum,
		})
	}
	if len(committed) > 0 {
		if device := batch[0].u.Device; device != "" {
			l.applyRetention(device, batch[0].u.Space, frame.Payload["retention"])
		}
	}
	out := map[string]any{
		"files":     committed,
		"committed": committed,
		"failed":    failed,
	}
	if upto, ok := payloadInt64(frame.Payload, "upto_seq"); ok && len(failed) == 0 {
		applied, err := l.cursors.advance(caller, upto)
		if err != nil {
			return nil, err
		}
		out["applied_seq"] = applied
	}
	return out, nil
}

func (l *Local) delete(frame protocol.Frame, caller string) (map[string]any, error) {
	device := frame.Device()
	if device == "" {
		device = caller
	}
	path, _ := frame.Payload["path"].(string)
	norm, err := protocol.NormalizePath(path)
	if err != nil {
		return nil, &OpError{Code: "bad_path", Msg: err.Error()}
	}
	recycled, err := l.moveToRecycle(device, frame.Space(), norm)
	if err != nil {
		return nil, err
	}
	out := map[string]any{"recycled": recycled}
	if upto, ok := payloadInt64(frame.Payload, "upto_seq"); ok {
		applied, err := l.cursors.advance(caller, upto)
		if err != nil {
			return nil, err
		}
		out["applied_seq"] = applied
	}
	return out, nil
}

func (l *Local) moveToRecycle(device, space, normalizedRel string) (string, error) {
	full, err := l.resolve(space, device, normalizedRel)
	if err != nil {
		return "", err
	}
	if _, err := os.Stat(full); err != nil {
		return "", &OpError{Code: "not_found", Msg: err.Error()}
	}
	date := time.Now().Format("2006-01-02")
	recycleRel := filepath.ToSlash(filepath.Join(".recycle", date, device, space, filepath.FromSlash(normalizedRel)))
	dest := filepath.Join(l.Root, filepath.FromSlash(recycleRel))
	if _, err := os.Stat(dest); err == nil {
		recycleRel = fmt.Sprintf("%s~%d", recycleRel, time.Now().UnixMilli())
		dest = filepath.Join(l.Root, filepath.FromSlash(recycleRel))
	}
	if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
		return "", err
	}
	if err := os.Rename(full, dest); err != nil {
		return "", err
	}
	return recycleRel, nil
}

func (l *Local) stats() (map[string]any, error) {
	devices := map[string]any{}
	ents, _ := os.ReadDir(l.Root)
	for _, e := range ents {
		if !e.IsDir() {
			continue
		}
		name := e.Name()
		if !protocol.IsValidDeviceID(name) {
			continue
		}
		perSpace := map[string]any{}
		for _, sp := range []string{"artifacts", "files", "attachments", "backups"} {
			perSpace[sp] = dirSize(filepath.Join(l.Root, name, sp), true)
		}
		devices[name] = perSpace
	}
	var stagingBytes int64
	for deviceID := range devices {
		for _, sp := range []string{"artifacts", "files", "attachments", "backups"} {
			stagingBytes += dirSize(filepath.Join(l.Root, deviceID, sp, ".staging"), false)
		}
	}
	out := map[string]any{
		"devices":       devices,
		"staging_bytes": stagingBytes,
		"recycle_bytes": dirSize(filepath.Join(l.Root, ".recycle"), false),
	}
	if p, err := l.loadPointer(); err == nil {
		out["master"] = p.Master
		out["master_epoch"] = p.Epoch
	}
	if cursors, err := l.cursors.all(); err == nil && len(cursors) > 0 {
		out["device_cursors"] = cursors
	}
	if total, free, ok := probeVolume(l.Root); ok {
		usedRatio := 0.0
		if total > 0 {
			used := total - free
			if used < 0 {
				used = 0
			}
			if used > total {
				used = total
			}
			usedRatio = float64(used) / float64(total)
		}
		out["volume_total_bytes"] = total
		out["volume_free_bytes"] = free
		out["volume_used_ratio"] = usedRatio
		out["volume_warn"] = usedRatio >= 0.8
	}
	return out, nil
}

func (l *Local) recycleList() (map[string]any, error) {
	dir := filepath.Join(l.Root, ".recycle")
	out := []map[string]any{}
	_ = filepath.Walk(dir, func(p string, info os.FileInfo, err error) error {
		if err != nil || info == nil {
			return nil
		}
		if info.IsDir() {
			if strings.HasPrefix(info.Name(), ".") && info.Name() != ".recycle" {
				return filepath.SkipDir
			}
			return nil
		}
		rel, err := filepath.Rel(l.Root, p)
		if err != nil {
			return nil
		}
		rel = filepath.ToSlash(rel)
		parts := strings.Split(rel, "/")
		// .recycle/<date>/<device>/<space>/<origin...>
		if len(parts) < 5 || parts[0] != ".recycle" {
			return nil
		}
		date := parts[1]
		device := parts[2]
		space := parts[3]
		originParts := append([]string{}, parts[4:]...)
		originParts[len(originParts)-1] = stripRecycleSuffix(originParts[len(originParts)-1])
		out = append(out, map[string]any{
			"recycle_path":  rel,
			"origin_device": device,
			"space":         space,
			"origin_path":   strings.Join(originParts, "/"),
			"size":          info.Size(),
			"deleted_at":    parseRecycleDateMs(date, info.ModTime()),
		})
		return nil
	})
	// newest first
	for i := 0; i < len(out); i++ {
		for j := i + 1; j < len(out); j++ {
			ai, _ := out[i]["deleted_at"].(int64)
			aj, _ := out[j]["deleted_at"].(int64)
			if aj > ai {
				out[i], out[j] = out[j], out[i]
			}
		}
	}
	return map[string]any{"entries": out}, nil
}

func (l *Local) recycleRestore(frame protocol.Frame) (map[string]any, error) {
	recyclePath, _ := frame.Payload["recycle_path"].(string)
	normalized := strings.ReplaceAll(recyclePath, "\\", "/")
	if !strings.HasPrefix(normalized, ".recycle/") || strings.Contains(normalized, "..") {
		return nil, &OpError{Code: "bad_path", Msg: "invalid recycle path"}
	}
	abs := filepath.Join(l.Root, filepath.FromSlash(normalized))
	if _, err := os.Stat(abs); err != nil {
		return nil, &OpError{Code: "not_found", Msg: recyclePath}
	}
	parts := strings.Split(normalized, "/")
	if len(parts) < 5 {
		return nil, &OpError{Code: "bad_path", Msg: "malformed recycle path"}
	}
	device := parts[2]
	space := parts[3]
	originParts := append([]string{}, parts[4:]...)
	originParts[len(originParts)-1] = stripRecycleSuffix(originParts[len(originParts)-1])
	originRel := strings.Join(originParts, "/")
	dest, err := l.resolve(space, device, originRel)
	if err != nil {
		return nil, err
	}
	if _, err := os.Stat(dest); err == nil {
		if _, err := l.moveToRecycle(device, space, originRel); err != nil {
			return nil, err
		}
	}
	if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
		return nil, err
	}
	if err := os.Rename(abs, dest); err != nil {
		return nil, err
	}
	l.pruneEmptyRecycleDirs()
	return map[string]any{"restored": originRel}, nil
}

func (l *Local) recycleEmpty() (map[string]any, error) {
	dir := filepath.Join(l.Root, ".recycle")
	purged := dirSize(dir, false)
	_ = os.RemoveAll(dir)
	_ = os.MkdirAll(dir, 0o755)
	return map[string]any{"purged_bytes": purged}, nil
}

func (l *Local) pruneEmptyRecycleDirs() {
	root := filepath.Join(l.Root, ".recycle")
	var dirs []string
	_ = filepath.Walk(root, func(p string, info os.FileInfo, err error) error {
		if err == nil && info != nil && info.IsDir() && p != root {
			dirs = append(dirs, p)
		}
		return nil
	})
	for i := len(dirs) - 1; i >= 0; i-- {
		_ = os.Remove(dirs[i]) // only succeeds if empty
	}
}

func stripRecycleSuffix(name string) string {
	if i := strings.LastIndex(name, "~"); i > 0 {
		suffix := name[i+1:]
		allDigit := len(suffix) >= 10
		for _, c := range suffix {
			if c < '0' || c > '9' {
				allDigit = false
				break
			}
		}
		if allDigit {
			return name[:i]
		}
	}
	return name
}

func parseRecycleDateMs(date string, fallback time.Time) int64 {
	t, err := time.ParseInLocation("2006-01-02", date, time.Local)
	if err != nil {
		return fallback.UnixMilli()
	}
	return t.UnixMilli()
}

func dirSize(path string, skipDotDirs bool) int64 {
	var total int64
	_ = filepath.Walk(path, func(p string, info os.FileInfo, err error) error {
		if err != nil || info == nil {
			return nil
		}
		if info.IsDir() {
			name := info.Name()
			if skipDotDirs && strings.HasPrefix(name, ".") && p != path {
				return filepath.SkipDir
			}
			return nil
		}
		total += info.Size()
		return nil
	})
	return total
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

// requireImportGrant enforces §5.4 for private-space reads of other devices.
func (l *Local) requireImportGrant(frame protocol.Frame, caller string) error {
	device := frame.Device()
	if device == "" || device == caller {
		return nil
	}
	space := frame.Space()
	if protocol.SharedReadable(space) {
		return nil
	}
	if seed, _ := frame.Payload["seed"].(bool); seed {
		if !l.isSeedAuthorized(caller) {
			return &OpError{Code: "acl_denied", Msg: "seed not authorized"}
		}
		return nil
	}
	grantID, _ := frame.Payload["grant"].(string)
	if grantID == "" {
		return &OpError{Code: "acl_denied", Msg: "import grant required"}
	}
	ok, err := l.imports.validate(grantID, device, caller, space)
	if err != nil {
		return err
	}
	if !ok {
		return &OpError{Code: "acl_denied", Msg: "invalid import grant"}
	}
	return nil
}

const seedAuthTTL = 15 * time.Minute

func (l *Local) authorizeSeed(caller string) {
	if caller == "" {
		return
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.seedAuth == nil {
		l.seedAuth = map[string]time.Time{}
	}
	l.seedAuth[caller] = time.Now().Add(seedAuthTTL)
}

func (l *Local) isSeedAuthorized(caller string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	exp, ok := l.seedAuth[caller]
	if !ok {
		return false
	}
	if time.Now().After(exp) {
		delete(l.seedAuth, caller)
		return false
	}
	return true
}

func (l *Local) importRequest(frame protocol.Frame, caller string) (map[string]any, error) {
	old, _ := frame.Payload["old_device"].(string)
	req, _, err := l.imports.createRequest(old, caller)
	if err != nil {
		return nil, err
	}
	return map[string]any{
		"request_id": req.RequestID,
		"status":     req.Status,
	}, nil
}

func (l *Local) importPending() (map[string]any, error) {
	pending, err := l.imports.pendingRequests()
	if err != nil {
		return nil, err
	}
	out := make([]map[string]any, 0, len(pending))
	for _, r := range pending {
		out = append(out, r.toMap())
	}
	return map[string]any{"requests": out}, nil
}

func (l *Local) importGrant(frame protocol.Frame) (map[string]any, error) {
	requestID, _ := frame.Payload["request_id"].(string)
	if requestID == "" {
		return nil, &OpError{Code: "bad_op", Msg: "request_id required"}
	}
	g, err := l.imports.grant(requestID)
	if err != nil {
		return nil, err
	}
	return map[string]any{"grant": g.toMap()}, nil
}

// ReceivePushedGrant persists an inbound no-req_id import.grant notification
// (path A/B). Prefer payload old_device when valid; else fall back to fromDevice.
func (l *Local) ReceivePushedGrant(fromDevice string, payload map[string]any) error {
	if payload == nil {
		return &OpError{Code: "bad_op", Msg: "empty grant"}
	}
	grantID, _ := payload["grant_id"].(string)
	if grantID == "" {
		return &OpError{Code: "bad_op", Msg: "grant_id required"}
	}
	payloadOld, _ := payload["old_device"].(string)
	oldDevice := fromDevice
	if protocol.IsValidDeviceID(payloadOld) {
		oldDevice = payloadOld
	}
	if !protocol.IsValidDeviceID(oldDevice) {
		return &OpError{Code: "bad_op", Msg: "invalid old_device"}
	}
	spaces := stringSlice(payload["spaces"])
	if len(spaces) == 0 {
		spaces = append([]string(nil), grantSpaces...)
	}
	g := importGrant{
		GrantID:   grantID,
		OldDevice: oldDevice,
		NewDevice: l.DeviceID,
		Spaces:    spaces,
		IssuedAt:  anyToInt64(payload["issued_at"]),
		ExpiresAt: anyToInt64(payload["expires_at"]),
	}
	if g.ExpiresAt <= 0 {
		g.ExpiresAt = time.Now().UnixMilli() + importDefaultTTL.Milliseconds()
	}
	return l.imports.saveReceived(g)
}

func stringSlice(v any) []string {
	switch x := v.(type) {
	case []string:
		return append([]string(nil), x...)
	case []any:
		out := make([]string, 0, len(x))
		for _, e := range x {
			if s, ok := e.(string); ok && s != "" {
				out = append(out, s)
			}
		}
		return out
	default:
		return nil
	}
}

func (l *Local) importReject(frame protocol.Frame) (map[string]any, error) {
	requestID, _ := frame.Payload["request_id"].(string)
	if requestID == "" {
		return nil, &OpError{Code: "bad_op", Msg: "request_id required"}
	}
	if err := l.imports.reject(requestID); err != nil {
		return nil, err
	}
	return map[string]any{"rejected": true}, nil
}

func (l *Local) importGrants(frame protocol.Frame) (map[string]any, error) {
	role, _ := frame.Payload["role"].(string)
	if role == "" {
		role = "received"
	}
	var grants []importGrant
	var err error
	if role == "issued" {
		grants, err = l.imports.issuedGrants()
	} else {
		grants, err = l.imports.receivedGrants()
	}
	if err != nil {
		return nil, err
	}
	out := make([]map[string]any, 0, len(grants))
	for _, g := range grants {
		out = append(out, g.toMap())
	}
	return map[string]any{"grants": out}, nil
}

func (l *Local) syncHello(caller string) (map[string]any, error) {
	if !protocol.IsValidDeviceID(caller) {
		return nil, &OpError{Code: "bad_path", Msg: "invalid caller"}
	}
	seq, err := l.cursors.appliedSeq(caller)
	if err != nil {
		return nil, err
	}
	return map[string]any{"applied_seq": seq}, nil
}

func (l *Local) syncCursors() (map[string]any, error) {
	m, err := l.cursors.all()
	if err != nil {
		return nil, err
	}
	// JSON-friendly map (empty object if none)
	out := make(map[string]any, len(m))
	for k, v := range m {
		out[k] = v
	}
	return map[string]any{"cursors": out}, nil
}
