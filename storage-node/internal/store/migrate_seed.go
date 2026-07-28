package store

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/shepaw/storage-node/internal/protocol"
)

// PeerRPC is optional live-session outbound store RPC (wired from peer.SessionRegistry).
type PeerRPC interface {
	Has(deviceID string) bool
	Call(deviceID, op string, payload map[string]any) (map[string]any, error)
}

// PeerEnsure dials a paired peer when not already connected (outbound reconnect).
type PeerEnsure interface {
	Ensure(deviceID string) error
	Release(deviceID string)
}

const (
	mirrorSeedListLimit       = 50000
	maxReportedHashMismatches = 50
)

// SetPeerRPC attaches live-session RPC used by master.migrate seed / hash gate.
func (l *Local) SetPeerRPC(rpc PeerRPC) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.peerRPC = rpc
}

// SetPeerEnsure attaches outbound dialer used when old master is not inbound.
func (l *Local) SetPeerEnsure(e PeerEnsure) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.peerEnsure = e
}

func (l *Local) getPeerRPC() PeerRPC {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.peerRPC
}

func (l *Local) getPeerEnsure() PeerEnsure {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.peerEnsure
}

// MergeCursors advances each device applied_seq to max(local, seed) (Dart seed semantics).
func (l *Local) MergeCursors(seed map[string]int64) (map[string]int64, error) {
	if len(seed) == 0 {
		return l.cursors.all()
	}
	for deviceID, seq := range seed {
		if !protocol.IsValidDeviceID(deviceID) || seq <= 0 {
			continue
		}
		if _, err := l.cursors.advance(deviceID, seq); err != nil {
			return nil, err
		}
	}
	return l.cursors.all()
}

// skippedHashGate matches Dart HashGateResult.skipped().
func skippedHashGate() map[string]any {
	return map[string]any{
		"ran":            false,
		"ok":             true,
		"devices":        []any{},
		"mismatches":     []any{},
		"mismatch_count": 0,
	}
}

// masterMigrate promotes this node to master.
// When PeerRPC is set and the previous master is online, pulls sync.cursors and
// mirror files via seed:true, then runs a soft MirrorHashGate before bumping.
// Payload require_hash_match=true hard-blocks on mismatches (Dart promoteSelf).
func (l *Local) masterMigrate(frame protocol.Frame) (map[string]any, error) {
	cur, err := l.loadPointer()
	if err != nil {
		return nil, err
	}
	requireMatch, _ := frame.Payload["require_hash_match"].(bool)
	oldMaster := cur.Master
	reachable := false
	seededFiles := 0
	hashGate := skippedHashGate()
	dialErr := ""
	rpc := l.getPeerRPC()
	ensure := l.getPeerEnsure()
	if rpc != nil && protocol.IsValidDeviceID(oldMaster) && oldMaster != l.DeviceID {
		if !rpc.Has(oldMaster) && ensure != nil {
			if err := ensure.Ensure(oldMaster); err != nil {
				log.Printf("master.migrate dial old master %s: %v", oldMaster, err)
				dialErr = err.Error()
			} else {
				defer ensure.Release(oldMaster)
			}
		}
		if rpc.Has(oldMaster) {
			n, deviceIDs, err := l.seedFromLiveMaster(rpc, oldMaster)
			if err != nil {
				log.Printf("master.migrate seed from %s: %v", oldMaster, err)
			} else {
				reachable = true
				seededFiles = n
				hashGate = l.runHashGate(rpc, oldMaster, deviceIDs)
				if requireMatch {
					ok, _ := hashGate["ok"].(bool)
					if !ok {
						return nil, &OpError{
							Code: "hash_gate",
							Msg:  "hash gate failed: mismatches present",
						}
					}
				}
			}
		}
	}

	epoch := cur.Epoch + 1
	if epoch < 1 {
		epoch = 1
	}
	next := masterPointer{Master: l.DeviceID, Epoch: epoch}
	if err := l.savePointer(next); err != nil {
		return nil, err
	}
	cursorsRaw, err := l.cursors.all()
	if err != nil {
		cursorsRaw = map[string]int64{}
	}
	cursors := make(map[string]any, len(cursorsRaw))
	for k, v := range cursorsRaw {
		cursors[k] = v
	}
	out := map[string]any{
		"master":               l.DeviceID,
		"epoch":                epoch,
		"old_master_reachable": reachable,
		"cursors":              cursors,
		"broadcast_peers":      0,
		"seeded_files":         seededFiles,
		"hash_gate":            hashGate,
	}
	if dialErr != "" {
		out["dial_error"] = dialErr
	}
	return out, nil
}

func (l *Local) seedFromLiveMaster(rpc PeerRPC, oldMaster string) (int, []string, error) {
	cursorsData, err := rpc.Call(oldMaster, "sync.cursors", map[string]any{})
	if err != nil {
		return 0, nil, err
	}
	seed := map[string]int64{}
	if raw, ok := cursorsData["cursors"].(map[string]any); ok {
		for k, v := range raw {
			seed[k] = anyToInt64(v)
		}
	}

	deviceSet := map[string]struct{}{}
	for id := range seed {
		deviceSet[id] = struct{}{}
	}
	if stats, err := rpc.Call(oldMaster, "stats", map[string]any{}); err == nil {
		if devices, ok := stats["devices"].(map[string]any); ok {
			for id := range devices {
				deviceSet[id] = struct{}{}
			}
		}
	}

	deviceIDs := make([]string, 0, len(deviceSet))
	for id := range deviceSet {
		if protocol.IsValidDeviceID(id) && id != l.DeviceID {
			deviceIDs = append(deviceIDs, id)
		}
	}

	written := 0
	completed := map[string]struct{}{l.DeviceID: {}}
	for _, deviceID := range deviceIDs {
		deviceOK := true
		for _, space := range []string{"artifacts", "files", "attachments", "backups"} {
			n, err := l.seedSpace(rpc, oldMaster, deviceID, space)
			if err != nil {
				log.Printf("seed %s/%s: %v", deviceID, space, err)
				deviceOK = false
				continue
			}
			written += n
		}
		if deviceOK {
			completed[deviceID] = struct{}{}
		}
	}

	// Only merge cursors for fully seeded devices (B2 seed gate).
	filtered := map[string]int64{}
	for id, seq := range seed {
		if _, ok := completed[id]; ok {
			filtered[id] = seq
		}
	}
	if _, err := l.MergeCursors(filtered); err != nil {
		return 0, nil, err
	}

	outIDs := make([]string, 0, len(completed))
	for id := range completed {
		if id != l.DeviceID {
			outIDs = append(outIDs, id)
		}
	}
	return written, outIDs, nil
}

func (l *Local) runHashGate(rpc PeerRPC, oldMaster string, deviceIDs []string) map[string]any {
	devicesOut := make([]any, 0)
	mismatches := make([]any, 0)
	for _, deviceID := range deviceIDs {
		if !protocol.IsValidDeviceID(deviceID) || deviceID == l.DeviceID {
			continue
		}
		remoteMap := map[string]string{}
		localMap := map[string]string{}
		for _, space := range []string{"artifacts", "files", "attachments", "backups"} {
			for k, sha := range l.listRemoteShas(rpc, oldMaster, deviceID, space) {
				remoteMap[space+"/"+k] = sha
			}
			for k, sha := range l.listLocalShas(deviceID, space) {
				localMap[space+"/"+k] = sha
			}
		}
		devicesOut = append(devicesOut, map[string]any{
			"device":         deviceID,
			"remote_digest":  digestPathMap(remoteMap),
			"local_digest":   digestPathMap(localMap),
			"matched":        digestPathMap(remoteMap) == digestPathMap(localMap),
		})
		keys := make([]string, 0, len(remoteMap)+len(localMap))
		seen := map[string]struct{}{}
		for k := range remoteMap {
			if _, ok := seen[k]; !ok {
				seen[k] = struct{}{}
				keys = append(keys, k)
			}
		}
		for k := range localMap {
			if _, ok := seen[k]; !ok {
				seen[k] = struct{}{}
				keys = append(keys, k)
			}
		}
		sort.Strings(keys)
		for _, key := range keys {
			if len(mismatches) >= maxReportedHashMismatches {
				break
			}
			slash := strings.IndexByte(key, '/')
			space, path := key, ""
			if slash >= 0 {
				space = key[:slash]
				path = key[slash+1:]
			}
			r, rOK := remoteMap[key]
			loc, lOK := localMap[key]
			switch {
			case rOK && !lOK:
				mismatches = append(mismatches, map[string]any{
					"device": deviceID, "space": space, "path": path,
					"kind": "missing_local", "remote_sha256": r,
				})
			case !rOK && lOK:
				mismatches = append(mismatches, map[string]any{
					"device": deviceID, "space": space, "path": path,
					"kind": "missing_remote", "local_sha256": loc,
				})
			case rOK && lOK && r != loc:
				mismatches = append(mismatches, map[string]any{
					"device": deviceID, "space": space, "path": path,
					"kind": "hash_mismatch", "remote_sha256": r, "local_sha256": loc,
				})
			}
		}
	}
	ok := len(mismatches) == 0
	return map[string]any{
		"ran":            true,
		"ok":             ok,
		"devices":        devicesOut,
		"mismatches":     mismatches,
		"mismatch_count": len(mismatches),
	}
}

func (l *Local) listRemoteShas(rpc PeerRPC, oldMaster, deviceID, space string) map[string]string {
	out := map[string]string{}
	res, err := rpc.Call(oldMaster, "list", map[string]any{
		"space": space, "device": deviceID, "path": "", "seed": true,
		"limit": mirrorSeedListLimit,
	})
	if err != nil {
		log.Printf("hash gate remote list %s/%s: %v", deviceID, space, err)
		return out
	}
	entries, _ := res["entries"].([]any)
	for _, raw := range entries {
		e, ok := raw.(map[string]any)
		if !ok {
			continue
		}
		path, _ := e["path"].(string)
		sha, _ := e["sha256"].(string)
		if path != "" && sha != "" {
			out[path] = sha
		}
	}
	return out
}

func (l *Local) listLocalShas(deviceID, space string) map[string]string {
	out := map[string]string{}
	listed, err := l.AdminList(deviceID, space, "")
	if err != nil {
		return out
	}
	switch entries := listed["entries"].(type) {
	case []map[string]any:
		for _, e := range entries {
			path, _ := e["path"].(string)
			sha, _ := e["sha256"].(string)
			if path != "" && sha != "" {
				out[path] = sha
			}
		}
	case []any:
		for _, raw := range entries {
			e, ok := raw.(map[string]any)
			if !ok {
				continue
			}
			path, _ := e["path"].(string)
			sha, _ := e["sha256"].(string)
			if path != "" && sha != "" {
				out[path] = sha
			}
		}
	}
	return out
}

func digestPathMap(pathToSha map[string]string) string {
	keys := make([]string, 0, len(pathToSha))
	for k := range pathToSha {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var b strings.Builder
	for _, k := range keys {
		b.WriteString(k)
		b.WriteByte(0)
		b.WriteString(pathToSha[k])
		b.WriteByte('\n')
	}
	sum := sha256.Sum256([]byte(b.String()))
	return hex.EncodeToString(sum[:])
}

func (l *Local) seedSpace(rpc PeerRPC, oldMaster, deviceID, space string) (int, error) {
	listRes, err := rpc.Call(oldMaster, "list", map[string]any{
		"space": space, "device": deviceID, "path": "", "seed": true,
		"limit": mirrorSeedListLimit,
	})
	if err != nil {
		return 0, err
	}
	entries, _ := listRes["entries"].([]any)
	written := 0
	for _, raw := range entries {
		e, ok := raw.(map[string]any)
		if !ok {
			continue
		}
		path, _ := e["path"].(string)
		sha, _ := e["sha256"].(string)
		size := anyToInt64(e["size"])
		if path == "" || sha == "" {
			continue
		}
		if l.localFileMatches(deviceID, space, path, sha) {
			continue
		}
		bytes, err := l.readAllRemote(rpc, oldMaster, deviceID, space, path, size)
		if err != nil {
			log.Printf("seed read %s/%s/%s: %v", deviceID, space, path, err)
			continue
		}
		sum := sha256.Sum256(bytes)
		if hex.EncodeToString(sum[:]) != sha {
			log.Printf("seed hash mismatch %s/%s/%s", deviceID, space, path)
			continue
		}
		if err := l.putMirrorFile(deviceID, space, path, bytes); err != nil {
			log.Printf("seed write %s/%s/%s: %v", deviceID, space, path, err)
			continue
		}
		written++
	}
	return written, nil
}

func (l *Local) localFileMatches(device, space, rel, sha string) bool {
	full, err := l.resolve(space, device, rel)
	if err != nil {
		return false
	}
	sum, _ := fileSHA(full)
	return sum == sha
}

func (l *Local) readAllRemote(rpc PeerRPC, oldMaster, device, space, path string, size int64) ([]byte, error) {
	var out []byte
	var offset int64
	for {
		res, err := rpc.Call(oldMaster, "read", map[string]any{
			"space": space, "device": device, "path": path,
			"offset": offset, "length": maxChunk, "seed": true,
		})
		if err != nil {
			return nil, err
		}
		b64, _ := res["data"].(string)
		chunk, err := base64.StdEncoding.DecodeString(b64)
		if err != nil {
			return nil, err
		}
		out = append(out, chunk...)
		offset += int64(len(chunk))
		eof, _ := res["eof"].(bool)
		if eof || len(chunk) == 0 {
			break
		}
	}
	if size > 0 && int64(len(out)) != size {
		return nil, &OpError{Code: "internal", Msg: "seed size mismatch"}
	}
	return out, nil
}

func (l *Local) putMirrorFile(device, space, rel string, data []byte) error {
	full, err := l.resolve(space, device, rel)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
		return err
	}
	tmp := full + ".seed-tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, full)
}
