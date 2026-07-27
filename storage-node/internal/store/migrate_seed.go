package store

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"log"
	"os"
	"path/filepath"

	"github.com/shepaw/storage-node/internal/protocol"
)

// PeerRPC is optional live-session outbound store RPC (wired from peer.SessionRegistry).
type PeerRPC interface {
	Has(deviceID string) bool
	Call(deviceID, op string, payload map[string]any) (map[string]any, error)
}

const mirrorSeedListLimit = 50000

// SetPeerRPC attaches live-session RPC used by master.migrate seed.
func (l *Local) SetPeerRPC(rpc PeerRPC) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.peerRPC = rpc
}

func (l *Local) getPeerRPC() PeerRPC {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.peerRPC
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

// masterMigrate promotes this node to master.
// When PeerRPC is set and the previous master is online, pulls sync.cursors and
// mirror files via seed:true before bumping the pointer.
func (l *Local) masterMigrate() (map[string]any, error) {
	cur, err := l.loadPointer()
	if err != nil {
		return nil, err
	}
	oldMaster := cur.Master
	reachable := false
	seededFiles := 0
	rpc := l.getPeerRPC()
	if rpc != nil && protocol.IsValidDeviceID(oldMaster) && oldMaster != l.DeviceID && rpc.Has(oldMaster) {
		if n, err := l.seedFromLiveMaster(rpc, oldMaster); err != nil {
			log.Printf("master.migrate seed from %s: %v", oldMaster, err)
		} else {
			reachable = true
			seededFiles = n
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
	return map[string]any{
		"master":               l.DeviceID,
		"epoch":                epoch,
		"old_master_reachable": reachable,
		"cursors":              cursors,
		"broadcast_peers":      0,
		"seeded_files":         seededFiles,
		"hash_gate": map[string]any{
			"ran":            false,
			"ok":             true,
			"devices":        []any{},
			"mismatches":     []any{},
			"mismatch_count": 0,
		},
	}, nil
}

func (l *Local) seedFromLiveMaster(rpc PeerRPC, oldMaster string) (int, error) {
	cursorsData, err := rpc.Call(oldMaster, "sync.cursors", map[string]any{})
	if err != nil {
		return 0, err
	}
	seed := map[string]int64{}
	if raw, ok := cursorsData["cursors"].(map[string]any); ok {
		for k, v := range raw {
			seed[k] = anyToInt64(v)
		}
	}
	if _, err := l.MergeCursors(seed); err != nil {
		return 0, err
	}

	deviceIDs := map[string]struct{}{}
	for id := range seed {
		deviceIDs[id] = struct{}{}
	}
	if stats, err := rpc.Call(oldMaster, "stats", map[string]any{}); err == nil {
		if devices, ok := stats["devices"].(map[string]any); ok {
			for id := range devices {
				deviceIDs[id] = struct{}{}
			}
		}
	}

	written := 0
	for deviceID := range deviceIDs {
		if !protocol.IsValidDeviceID(deviceID) || deviceID == l.DeviceID {
			continue
		}
		for _, space := range []string{"artifacts", "files", "attachments", "backups"} {
			n, err := l.seedSpace(rpc, oldMaster, deviceID, space)
			if err != nil {
				log.Printf("seed %s/%s: %v", deviceID, space, err)
				continue
			}
			written += n
		}
	}
	return written, nil
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
