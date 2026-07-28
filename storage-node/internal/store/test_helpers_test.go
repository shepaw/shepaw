package store_test

import (
	"crypto/sha256"
	"encoding/hex"
)

func testSHA(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

func writeBeginPayload(space, path string, body []byte) map[string]any {
	return map[string]any{
		"space":  space,
		"path":   path,
		"size":   len(body),
		"sha256": testSHA(body),
	}
}
