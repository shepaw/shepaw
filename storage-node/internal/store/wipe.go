package store

import (
	"os"
	"path/filepath"

	"github.com/shepaw/storage-node/internal/protocol"
)

// WipeSelf clears this node's own device tree (four partitions + staging).
// Does not touch other mirrors, .recycle, or .system (aligned with Dart LocalStore.wipeSelf).
func (l *Local) WipeSelf(selfDeviceID string) (int64, error) {
	if !protocol.IsValidDeviceID(selfDeviceID) {
		return 0, &OpError{Code: "bad_path", Msg: "invalid device id"}
	}
	if selfDeviceID != l.DeviceID {
		return 0, &OpError{Code: "acl_denied", Msg: "can only wipe self"}
	}
	dir := filepath.Join(l.Root, selfDeviceID)
	st, err := os.Stat(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return 0, nil
		}
		return 0, err
	}
	if !st.IsDir() {
		return 0, &OpError{Code: "bad_path", Msg: "not a device directory"}
	}
	freed := dirSize(dir, false)
	if err := os.RemoveAll(dir); err != nil {
		return 0, err
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return 0, err
	}
	return freed, nil
}
