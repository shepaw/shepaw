package store

import (
	"encoding/json"
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
	_ = removeDeviceCursor(l.Root, deviceID)
	return freed, nil
}

func removeDeviceCursor(root, deviceID string) error {
	path := filepath.Join(root, ".system", "device_cursors.json")
	raw, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	var m map[string]any
	if err := json.Unmarshal(raw, &m); err != nil {
		return err
	}
	if _, ok := m[deviceID]; !ok {
		return nil
	}
	delete(m, deviceID)
	out, err := json.Marshal(m)
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, out, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}
