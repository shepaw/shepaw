package store

import (
	"os"
	"path/filepath"
	"time"

	"github.com/shepaw/storage-node/internal/protocol"
)

// GcStaging removes abandoned staging upload dirs older than olderThan
// (default 24h, aligned with Dart LocalStore.gcStaging / spec §2.4).
// Returns the number of upload directories removed.
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
		for _, sp := range []string{"artifacts", "files", "attachments", "backups"} {
			staging := filepath.Join(l.Root, e.Name(), sp, ".staging")
			uploads, err := os.ReadDir(staging)
			if err != nil {
				continue
			}
			for _, u := range uploads {
				if !u.IsDir() {
					continue
				}
				path := filepath.Join(staging, u.Name())
				info, err := os.Stat(path)
				if err != nil {
					continue
				}
				if info.ModTime().Before(deadline) {
					if err := os.RemoveAll(path); err == nil {
						removed++
					}
				}
			}
		}
	}
	return removed, nil
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
