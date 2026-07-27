package store

import (
	"os"
	"path/filepath"
	"strings"

	"github.com/shepaw/storage-node/internal/protocol"
)

// AdminList lists files under device/space[/path] without peer ACL / import grant.
// Used by headless /admin browse (aligned with App StorageBrowserScreen → LocalStore.list).
func (l *Local) AdminList(device, space, path string) (map[string]any, error) {
	if !protocol.IsValidDeviceID(device) {
		return nil, &OpError{Code: "bad_path", Msg: "invalid device id"}
	}
	if !protocol.IsValidSpace(space) {
		return nil, &OpError{Code: "bad_op", Msg: "invalid space"}
	}
	dir, err := l.resolve(space, device, path)
	if err != nil {
		return nil, err
	}
	st, err := os.Stat(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return map[string]any{"entries": []map[string]any{}}, nil
		}
		return nil, err
	}
	if !st.IsDir() {
		sum, size := fileSHA(dir)
		rel := filepath.Base(dir)
		if path != "" {
			norm, nerr := protocol.NormalizePath(path)
			if nerr == nil {
				rel = norm
			}
		}
		return map[string]any{"entries": []map[string]any{{
			"path": rel, "size": size, "sha256": sum, "mtime": st.ModTime().UnixMilli(),
		}}}, nil
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
		rel, _ := filepath.Rel(dir, p)
		rel = filepath.ToSlash(rel)
		if path != "" {
			base, _ := protocol.NormalizePath(path)
			rel = strings.TrimSuffix(base, "/") + "/" + rel
			rel = strings.TrimPrefix(rel, "/")
		}
		sum, size := fileSHA(p)
		entries = append(entries, map[string]any{
			"path": rel, "size": size, "sha256": sum, "mtime": info.ModTime().UnixMilli(),
		})
		return nil
	})
	return map[string]any{"entries": entries}, nil
}

// AdminDelete moves a file into recycle without peer ACL (headless master browse).
func (l *Local) AdminDelete(device, space, path string) (map[string]any, error) {
	if !protocol.IsValidDeviceID(device) {
		return nil, &OpError{Code: "bad_path", Msg: "invalid device id"}
	}
	if !protocol.IsValidSpace(space) {
		return nil, &OpError{Code: "bad_op", Msg: "invalid space"}
	}
	norm, err := protocol.NormalizePath(path)
	if err != nil {
		return nil, &OpError{Code: "bad_path", Msg: err.Error()}
	}
	recycled, err := l.moveToRecycle(device, space, norm)
	if err != nil {
		return nil, err
	}
	return map[string]any{"recycled": recycled}, nil
}
