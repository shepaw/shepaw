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
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/shepaw/storage-node/internal/protocol"
)

var uploadIDPattern = regexp.MustCompile(`^[A-Za-z0-9-]{1,64}$`)

func checkUploadID(id string) error {
	if !uploadIDPattern.MatchString(id) {
		return &OpError{Code: "bad_op", Msg: "invalid upload_id"}
	}
	return nil
}

func isHexSHA256(s string) bool {
	if len(s) != 64 {
		return false
	}
	for _, c := range s {
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
			return false
		}
	}
	return true
}

type stagingMeta struct {
	Path      string `json:"path"`
	Size      int64  `json:"size"`
	Sha256    string `json:"sha256"`
	CreatedMs int64  `json:"created_ms"`
}

func (l *Local) writeBegin(frame protocol.Frame, caller string) (map[string]any, error) {
	path, _ := frame.Payload["path"].(string)
	norm, err := protocol.NormalizePath(path)
	if err != nil {
		return nil, &OpError{Code: "bad_path", Msg: err.Error()}
	}
	space := frame.Space()
	size := int64(num(frame.Payload["size"]))
	sha, _ := frame.Payload["sha256"].(string)
	if size < 0 {
		return nil, &OpError{Code: "bad_op", Msg: "negative size"}
	}
	if sha == "" || !isHexSHA256(sha) {
		return nil, &OpError{Code: "bad_op", Msg: "invalid sha256"}
	}
	if err := l.enforceWriteQuota(caller, space, size); err != nil {
		return nil, err
	}

	id, _ := frame.Payload["upload_id"].(string)
	if id == "" {
		id = fmt.Sprintf("u-%d", time.Now().UnixNano())
	}
	if err := checkUploadID(id); err != nil {
		return nil, err
	}

	stagingDir := filepath.Join(l.Root, caller, space, ".staging")
	if err := os.MkdirAll(stagingDir, 0o755); err != nil {
		return nil, err
	}
	partPath := filepath.Join(stagingDir, id+".part")
	metaPath := filepath.Join(stagingDir, id+".json")

	if raw, err := os.ReadFile(metaPath); err == nil {
		var meta stagingMeta
		if json.Unmarshal(raw, &meta) == nil {
			if meta.Path != norm || meta.Size != size || (sha != "" && meta.Sha256 != "" && meta.Sha256 != sha) {
				return nil, &OpError{Code: "staging_state", Msg: "upload_id conflicts with existing"}
			}
			received := int64(0)
			if st, err := os.Stat(partPath); err == nil {
				received = st.Size()
			}
			l.mu.Lock()
			l.uploads[id] = &upload{
				Device: caller, Space: space, Path: norm,
				Tmp: partPath, MetaPath: metaPath,
				DeclaredSize: size, DeclaredSha: meta.Sha256,
				Received: received, writeMu: &sync.Mutex{},
			}
			l.mu.Unlock()
			return map[string]any{"upload_id": id, "received": received}, nil
		}
	}

	meta := stagingMeta{
		Path: norm, Size: size, Sha256: sha,
		CreatedMs: time.Now().UnixMilli(),
	}
	raw, _ := json.Marshal(meta)
	if err := os.WriteFile(metaPath, raw, 0o644); err != nil {
		return nil, err
	}
	f, err := os.OpenFile(partPath, os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		return nil, err
	}
	_ = f.Close()

	l.mu.Lock()
	l.uploads[id] = &upload{
		Device: caller, Space: space, Path: norm,
		Tmp: partPath, MetaPath: metaPath,
		DeclaredSize: size, DeclaredSha: sha,
		Received: 0, writeMu: &sync.Mutex{},
	}
	l.mu.Unlock()
	return map[string]any{"upload_id": id, "received": 0}, nil
}

func (l *Local) writeChunk(frame protocol.Frame) (map[string]any, error) {
	id, _ := frame.Payload["upload_id"].(string)
	if err := checkUploadID(id); err != nil {
		return nil, err
	}
	dataB64, _ := frame.Payload["data"].(string)
	raw, err := base64.StdEncoding.DecodeString(dataB64)
	if err != nil {
		return nil, &OpError{Code: "bad_op", Msg: "bad base64"}
	}
	if len(raw) > maxChunk {
		return nil, &OpError{Code: "bad_op", Msg: "chunk too large"}
	}
	offset := int64(num(frame.Payload["offset"]))

	l.mu.Lock()
	u := l.uploads[id]
	l.mu.Unlock()
	if u == nil {
		return nil, &OpError{Code: "staging_state", Msg: "unknown upload"}
	}

	u.writeMu.Lock()
	defer u.writeMu.Unlock()

	if offset > u.Received {
		return nil, &OpError{Code: "staging_state",
			Msg: fmt.Sprintf("offset %d beyond received %d", offset, u.Received)}
	}
	if u.DeclaredSize > 0 && offset+int64(len(raw)) > u.DeclaredSize {
		return nil, &OpError{Code: "bad_op", Msg: "chunk exceeds declared size"}
	}

	f, err := os.OpenFile(u.Tmp, os.O_RDWR, 0o644)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	if _, err := f.WriteAt(raw, offset); err != nil {
		return nil, err
	}
	end := offset + int64(len(raw))
	if end > u.Received {
		u.Received = end
	}
	return map[string]any{"received": u.Received, "accepted": len(raw)}, nil
}

func (l *Local) commit(frame protocol.Frame, caller string) (map[string]any, error) {
	ids, _ := frame.Payload["upload_ids"].([]any)
	if ids == nil {
		if one, ok := frame.Payload["upload_id"].(string); ok {
			ids = []any{one}
		}
	}
	type pending struct {
		id   string
		u    *upload
		sum  string
		size int64
	}
	batch := make([]pending, 0, len(ids))
	for _, rawID := range ids {
		id, _ := rawID.(string)
		if err := checkUploadID(id); err != nil {
			return nil, err
		}
		l.mu.Lock()
		u := l.uploads[id]
		l.mu.Unlock()
		if u == nil {
			return nil, &OpError{Code: "staging_state", Msg: "unknown " + id}
		}
		meta := stagingMeta{Path: u.Path, Size: u.DeclaredSize, Sha256: u.DeclaredSha}
		if raw, err := os.ReadFile(u.MetaPath); err == nil {
			_ = json.Unmarshal(raw, &meta)
		}
		sum, size, err := fileSHAExact(u.Tmp)
		if err != nil {
			return nil, &OpError{Code: "staging_state", Msg: err.Error()}
		}
		if meta.Size >= 0 && size != meta.Size {
			return nil, &OpError{Code: "hash_mismatch", Msg: id + ": size"}
		}
		if meta.Sha256 != "" && sum != meta.Sha256 {
			return nil, &OpError{Code: "hash_mismatch", Msg: id}
		}
		batch = append(batch, pending{id: id, u: u, sum: sum, size: size})
	}

	committed := []map[string]any{}
	failed := []map[string]any{}
	for _, p := range batch {
		dest := filepath.Join(l.Root, p.u.Device, p.u.Space, filepath.FromSlash(p.u.Path))
		if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
			failed = append(failed, map[string]any{"upload_id": p.id, "error": err.Error()})
			continue
		}
		if err := rejectSymlinkUnder(
			filepath.Join(l.Root, p.u.Device, p.u.Space), dest); err != nil {
			failed = append(failed, map[string]any{"upload_id": p.id, "error": err.Error()})
			continue
		}
		if _, err := os.Lstat(dest); err == nil {
			if _, err := l.moveToRecycle(p.u.Device, p.u.Space, p.u.Path); err != nil {
				failed = append(failed, map[string]any{"upload_id": p.id, "error": err.Error()})
				continue
			}
		}
		if err := os.Rename(p.u.Tmp, dest); err != nil {
			failed = append(failed, map[string]any{"upload_id": p.id, "error": err.Error()})
			continue
		}
		_ = os.Remove(p.u.MetaPath)
		l.mu.Lock()
		delete(l.uploads, p.id)
		l.mu.Unlock()
		committed = append(committed, map[string]any{
			"upload_id": p.id, "path": p.u.Path, "size": p.size, "sha256": p.sum,
		})
		l.appendEvent("file.committed", p.u.Device, p.u.Space, p.u.Path, map[string]any{
			"size": p.size, "sha256": p.sum,
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

func fileSHAExact(path string) (string, int64, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", 0, err
	}
	defer f.Close()
	h := sha256.New()
	n, err := io.Copy(h, f)
	if err != nil {
		return "", 0, err
	}
	return hex.EncodeToString(h.Sum(nil)), n, nil
}

// rejectSymlinkUnder walks from spaceRoot down to path (inclusive) and
// rejects any symlink segment. Paths outside spaceRoot are ignored for
// parent walks so OS temp-dir symlinks (/var → /private/var) do not trip.
func rejectSymlinkUnder(spaceRoot, path string) error {
	spaceRoot = filepath.Clean(spaceRoot)
	path = filepath.Clean(path)
	if path != spaceRoot && !strings.HasPrefix(path, spaceRoot+string(os.PathSeparator)) {
		return &OpError{Code: "bad_path", Msg: "escape"}
	}
	rel, err := filepath.Rel(spaceRoot, path)
	if err != nil {
		return &OpError{Code: "bad_path", Msg: err.Error()}
	}
	// Check space root itself if it exists.
	if fi, err := os.Lstat(spaceRoot); err == nil {
		if fi.Mode()&os.ModeSymlink != 0 {
			return &OpError{Code: "bad_path", Msg: "symlink not allowed"}
		}
	} else if !os.IsNotExist(err) {
		return err
	}
	if rel == "." {
		return nil
	}
	cur := spaceRoot
	for _, seg := range strings.Split(rel, string(os.PathSeparator)) {
		if seg == "" || seg == "." {
			continue
		}
		cur = filepath.Join(cur, seg)
		fi, err := os.Lstat(cur)
		if err != nil {
			if os.IsNotExist(err) {
				// Remaining parents don't exist yet — OK for write promote.
				return nil
			}
			return err
		}
		if fi.Mode()&os.ModeSymlink != 0 {
			return &OpError{Code: "bad_path", Msg: "symlink not allowed"}
		}
	}
	return nil
}

const defaultAgentQuota = int64(2 * 1024 * 1024 * 1024)
const volumeHeadroom = int64(64 * 1024 * 1024)

func (l *Local) enforceWriteQuota(device, space string, size int64) error {
	if l.VolumeFreeOverride != nil {
		if *l.VolumeFreeOverride < size+volumeHeadroom {
			return &OpError{Code: "quota_exceeded", Msg: "volume budget"}
		}
	} else if _, free, ok := probeVolume(l.Root); ok {
		if free < size {
			return &OpError{Code: "quota_exceeded", Msg: "volume budget"}
		}
	}
	capBytes := l.AgentQuotaBytes
	if capBytes == 0 {
		capBytes = defaultAgentQuota
	}
	if capBytes < 0 {
		return nil
	}
	if !protocol.AgentQuotaSpace(space) {
		return nil
	}
	var used int64
	for _, sp := range []string{"runtime", "artifacts", "attachments", "cognition"} {
		used += dirSize(filepath.Join(l.Root, device, sp), true)
	}
	if used+size > capBytes {
		return &OpError{Code: "quota_exceeded", Msg: "agent space quota"}
	}
	return nil
}
