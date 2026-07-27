package store

import (
	"os"
	"path/filepath"

	"github.com/shepaw/storage-node/internal/protocol"
)

// PurgeDevice permanently removes another device's mirror tree and clears its
// cursor entry (aligned with Dart LocalStore.purgeDevice + DeviceCursorStore.remove).
// Cannot purge self.
func (l *Local) PurgeDevice(deviceID, selfDeviceID string) (int64, error) {
	if !protocol.IsValidDeviceID(deviceID) {
		return 0, &OpError{Code: "bad_path", Msg: "invalid device id"}
	}
	if deviceID == selfDeviceID {
		return 0, &OpError{Code: "acl_denied", Msg: "cannot purge self"}
	}
	dir := filepath.Join(l.Root, deviceID)
	st, err := os.Stat(dir)
	if err != nil || !st.IsDir() {
		return 0, &OpError{Code: "not_found", Msg: deviceID}
	}
	freed := dirSize(dir, false)
	if err := os.RemoveAll(dir); err != nil {
		return 0, err
	}
	_ = l.cursors.remove(deviceID)
	return freed, nil
}
