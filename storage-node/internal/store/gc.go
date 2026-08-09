package store

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/shepaw/storage-node/internal/protocol"
)

// GcStaging removes abandoned staging sessions older than olderThan
// (default 24h, aligned with Dart LocalStore.gcStaging / spec §2.4).
//
// Layout: .staging/<upload_id>.{part,json} (flat files). Age uses
// created_ms from the .json meta when present, else file mtime — so
// active chunk writes cannot keep a session alive past the create TTL.
// Also removes legacy per-upload directories from older Go builds.
// Returns the number of upload sessions removed.
func (l *Local) GcStaging(olderThan time.Duration) (int, error) {
	if olderThan <= 0 {
		olderThan = 24 * time.Hour
	}
	deadline := time.Now().Add(-olderThan)
	ents, err := os.ReadDir(l.Root)
	if err != nil {
		if os.IsNotExist(err) {
			return 0, nil
		}
		return 0, err
	}
	removed := 0
	for _, e := range ents {
		if !e.IsDir() || !protocol.IsValidDeviceID(e.Name()) {
			continue
		}
		for _, sp := range protocol.BuiltinSpaces() {
			staging := filepath.Join(l.Root, e.Name(), sp, ".staging")
			uploads, err := os.ReadDir(staging)
			if err != nil {
				continue
			}
			seen := map[string]bool{}
			for _, u := range uploads {
				name := u.Name()
				path := filepath.Join(staging, name)
				if u.IsDir() {
					// Legacy dir layout (.staging/<id>/blob)
					info, err := os.Stat(path)
					if err != nil {
						continue
					}
					if info.ModTime().Before(deadline) {
						if err := os.RemoveAll(path); err == nil {
							removed++
							l.forgetUpload(name)
						}
					}
					continue
				}
				id := stagingSessionID(name)
				if id == "" || seen[id] {
					continue
				}
				seen[id] = true
				created := stagingCreated(staging, id, path)
				if created.Before(deadline) {
					_ = os.Remove(filepath.Join(staging, id+".part"))
					_ = os.Remove(filepath.Join(staging, id+".json"))
					removed++
					l.forgetUpload(id)
				}
			}
		}
	}
	return removed, nil
}

func stagingSessionID(name string) string {
	switch {
	case strings.HasSuffix(name, ".json"):
		return strings.TrimSuffix(name, ".json")
	case strings.HasSuffix(name, ".part"):
		return strings.TrimSuffix(name, ".part")
	default:
		return ""
	}
}

func stagingCreated(stagingDir, id, fallbackPath string) time.Time {
	metaPath := filepath.Join(stagingDir, id+".json")
	if raw, err := os.ReadFile(metaPath); err == nil {
		var meta stagingMeta
		if json.Unmarshal(raw, &meta) == nil && meta.CreatedMs > 0 {
			return time.UnixMilli(meta.CreatedMs)
		}
	}
	info, err := os.Stat(fallbackPath)
	if err != nil {
		return time.Time{}
	}
	return info.ModTime()
}

func (l *Local) forgetUpload(id string) {
	l.mu.Lock()
	delete(l.uploads, id)
	l.mu.Unlock()
}

// GcRecycle removes recycle date directories older than olderThan
// (default 30d, aligned with Dart LocalStore.gcRecycle / spec §2.7).
// Returns purged bytes.
func (l *Local) GcRecycle(olderThan time.Duration) (int64, error) {
	if olderThan <= 0 {
		olderThan = 30 * 24 * time.Hour
	}
	recycleDir := filepath.Join(l.Root, ".recycle")
	ents, err := os.ReadDir(recycleDir)
	if err != nil {
		if os.IsNotExist(err) {
			return 0, nil
		}
		return 0, err
	}
	now := time.Now()
	cutoff := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, now.Location()).Add(-olderThan)
	var purged int64
	for _, e := range ents {
		if !e.IsDir() {
			continue
		}
		parsed, err := time.Parse("2006-01-02", e.Name())
		if err != nil {
			continue
		}
		dateOnly := time.Date(parsed.Year(), parsed.Month(), parsed.Day(), 0, 0, 0, 0, time.UTC)
		if !dateOnly.Before(cutoff) {
			continue
		}
		path := filepath.Join(recycleDir, e.Name())
		purged += dirSize(path, false)
		_ = os.RemoveAll(path)
	}
	l.pruneEmptyRecycleDirs()
	return purged, nil
}

// StartPeriodicGC runs staging + recycle cleanup on an interval (default 1h).
// Safe to call once after Open; stop with StopPeriodicGC.
func (l *Local) StartPeriodicGC(every time.Duration) {
	if every <= 0 {
		every = time.Hour
	}
	l.mu.Lock()
	if l.gcStop != nil {
		l.mu.Unlock()
		return
	}
	stop := make(chan struct{})
	l.gcStop = stop
	l.mu.Unlock()
	go func() {
		t := time.NewTicker(every)
		defer t.Stop()
		for {
			select {
			case <-stop:
				return
			case <-t.C:
				_, _ = l.GcStaging(0)
				_, _ = l.GcRecycle(0)
			}
		}
	}()
}

func (l *Local) StopPeriodicGC() {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.gcStop != nil {
		close(l.gcStop)
		l.gcStop = nil
	}
}
