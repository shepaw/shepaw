//go:build unix

package store

import "syscall"

func probeVolume(path string) (total, free int64, ok bool) {
	var st syscall.Statfs_t
	if err := syscall.Statfs(path, &st); err != nil {
		return 0, 0, false
	}
	bsize := int64(st.Bsize)
	if bsize <= 0 {
		return 0, 0, false
	}
	total = int64(st.Blocks) * bsize
	free = int64(st.Bavail) * bsize
	if total <= 0 {
		return 0, 0, false
	}
	return total, free, true
}
