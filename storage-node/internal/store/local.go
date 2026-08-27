// Package store implements a filesystem-backed store.* root for the headless node.
package store

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
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
	gcStop     chan struct{}
	// AgentQuotaBytes overrides the 2GiB default; -1 disables.
	AgentQuotaBytes int64
	// VolumeFreeOverride, when set, is used instead of probing the volume.
	VolumeFreeOverride *int64
}

// upload tracks an in-flight write; durable state lives in .staging/<id>.{part,json}.
type upload struct {
	Device       string
	Space        string
	Path         string
	Tmp          string
	MetaPath     string
	DeclaredSize int64
	DeclaredSha  string
	Received     int64
	writeMu      *sync.Mutex
}

func Open(root, deviceID string) (*Local, error) {
	if !protocol.IsValidDeviceID(deviceID) {
		return nil, fmt.Errorf("bad device id")
	}
	if err := os.MkdirAll(root, 0o755); err != nil {
		return nil, err
	}
	for _, sp := range protocol.BuiltinSpaces() {
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
	if v := protocol.CheckACLEx(frame, caller, trust, loopback, nil, l.spaceVis); v != protocol.Allow {
		return nil, &OpError{Code: aclCode(v), Msg: string(v)}
	}
	// Fencing: demoted nodes must not accept sync mutations / hello (B2).
	if needsMasterFence(frame) {
		if err := l.requireMaster(); err != nil {
			return nil, err
		}
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
	case "space.list":
		return l.spaceList(frame)
	case "space.declare":
		return l.spaceDeclare(frame, caller)
	case "search":
		return l.search(frame, caller)
	case "events.list":
		return l.eventsList(frame)
	default:
		return nil, &OpError{Code: "bad_op", Msg: frame.Op}
	}
}

func needsMasterFence(frame protocol.Frame) bool {
	if frame.Op == "sync.hello" {
		return true
	}
	if frame.Op == "commit" || frame.Op == "delete" {
		_, ok := payloadInt64(frame.Payload, "upto_seq")
		return ok
	}
	return false
}

func (l *Local) requireMaster() error {
	p, err := l.loadPointer()
	if err != nil {
		return err
	}
	if p.Master != l.DeviceID {
		return &OpError{
			Code: "not_master",
			Msg:  fmt.Sprintf("master=%s epoch=%d", p.Master, p.Epoch),
		}
	}
	return nil
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
		if err := rejectSymlinkUnder(base, base); err != nil {
			return "", err
		}
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
	if err := rejectSymlinkUnder(base, full); err != nil {
		return "", err
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
	spaceRoot, err := l.resolve(frame.Space(), device, "")
	if err != nil {
		return nil, err
	}
	dir, err := l.resolve(frame.Space(), device, path)
	if err != nil {
		return nil, err
	}
	limit := int(num(frame.Payload["limit"]))
	if limit <= 0 {
		limit = 1000
	}
	entries := []map[string]any{}
	_ = filepath.Walk(dir, func(p string, info os.FileInfo, err error) error {
		if err != nil {
			return nil
		}
		if info.IsDir() {
			name := info.Name()
			if strings.HasPrefix(name, ".") || name == ".staging" {
				if p == dir {
					return nil
				}
				return filepath.SkipDir
			}
			return nil
		}
		if strings.HasPrefix(info.Name(), ".") {
			return nil
		}
		rel, _ := filepath.Rel(spaceRoot, p)
		rel = filepath.ToSlash(rel)
		sum, size := fileSHA(p)
		entries = append(entries, map[string]any{
			"path": rel, "size": size, "sha256": sum, "mtime": info.ModTime().UnixMilli(),
		})
		if len(entries) >= limit {
			return io.EOF
		}
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
	out := map[string]any{}
	recycled, err := l.moveToRecycle(device, frame.Space(), norm)
	if err != nil {
		// Idempotent delete: already-gone is success (sync replay / B2).
		if oe, ok := err.(*OpError); ok && oe.Code == "not_found" {
			out["recycled"] = ""
			out["already_gone"] = true
		} else {
			return nil, err
		}
	} else {
		out["recycled"] = recycled
		l.appendEvent("file.deleted", device, frame.Space(), norm, map[string]any{"recycled": recycled})
	}
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
		for _, sp := range protocol.BuiltinSpaces() {
			perSpace[sp] = dirSize(filepath.Join(l.Root, name, sp), true)
		}
		devices[name] = perSpace
	}
	var stagingBytes int64
	for deviceID := range devices {
		for _, sp := range protocol.BuiltinSpaces() {
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
