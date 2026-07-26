//go:build !unix

package store

func probeVolume(path string) (total, free int64, ok bool) {
	return 0, 0, false
}
