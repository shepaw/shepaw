// Package protocol mirrors lib/storage/store_protocol.dart (path + ACL).
package protocol

import (
	"fmt"
	"regexp"
	"strings"
)

const ProtocolVersion = 4

type AclVerdict string

const (
	Allow          AclVerdict = "allow"
	DenyUntrusted  AclVerdict = "denyUntrusted"
	DenyAcl        AclVerdict = "denyAcl"
	DenyBadOp      AclVerdict = "denyBadOp"
	DenyBadPath    AclVerdict = "denyBadPath"
)

const (
	TrustOwner  = "owner"
	TrustFriend = "friend"
)

var (
	deviceIDRe = regexp.MustCompile(`^[0-9a-f]{16}$`)
	driveRe   = regexp.MustCompile(`(?i)^[a-z]:[\\/]?`)
)

type Frame struct {
	Op      string
	Payload map[string]any
}

func (f Frame) Space() string {
	if v, ok := f.Payload["space"].(string); ok {
		return v
	}
	return ""
}

func (f Frame) Device() string {
	if v, ok := f.Payload["device"].(string); ok {
		return v
	}
	return ""
}

func IsValidDeviceID(device string) bool {
	return deviceIDRe.MatchString(device)
}

func IsValidSpace(s string) bool {
	switch s {
	case "artifacts", "files", "attachments", "backups":
		return true
	default:
		return false
	}
}

func SharedReadable(s string) bool {
	return s == "artifacts" || s == "files"
}

// NormalizePath mirrors Dart normalizeStorePath.
func NormalizePath(raw string) (string, error) {
	if raw == "" {
		return "", fmt.Errorf("empty path")
	}
	if strings.ContainsRune(raw, 0) {
		return "", fmt.Errorf("NUL in path")
	}
	if strings.HasPrefix(raw, "/") || strings.HasPrefix(raw, "~") {
		return "", fmt.Errorf("absolute path")
	}
	if driveRe.MatchString(raw) || strings.HasPrefix(raw, `\\`) {
		return "", fmt.Errorf("drive/unc path")
	}
	segments := strings.Split(strings.ReplaceAll(raw, `\`, `/`), "/")
	out := make([]string, 0, len(segments))
	for _, seg := range segments {
		if seg == "" || seg == "." {
			continue
		}
		if seg == ".." {
			return "", fmt.Errorf("path traversal")
		}
		if strings.HasPrefix(seg, ".") {
			return "", fmt.Errorf("dot segment: %s", seg)
		}
		out = append(out, seg)
	}
	if len(out) == 0 {
		return "", fmt.Errorf("resolves to empty")
	}
	return strings.Join(out, "/"), nil
}

// CheckACL mirrors Dart checkStoreAcl (M2–M4 ops used by fixtures).
func CheckACL(frame Frame, callerDeviceID, trustLevel string, loopback bool) AclVerdict {
	if trustLevel != TrustOwner {
		return DenyUntrusted
	}
	space := frame.Space()
	device := frame.Device()

	switch frame.Op {
	case "write.begin", "write.chunk", "commit":
		if space != "" && !IsValidSpace(space) {
			return DenyBadOp
		}
		if frame.Op == "write.begin" && space == "" {
			return DenyBadOp
		}
		if device != "" && device != callerDeviceID {
			return DenyAcl
		}
		return Allow

	case "delete":
		if space == "" || !IsValidSpace(space) {
			return DenyBadOp
		}
		targetOwn := device == "" || device == callerDeviceID
		if !targetOwn && !SharedReadable(space) {
			return DenyAcl
		}
		if device != "" && !IsValidDeviceID(device) {
			return DenyBadOp
		}
		return Allow

	case "list", "meta", "read":
		if space == "" || !IsValidSpace(space) {
			return DenyBadOp
		}
		targetOwn := device == "" || device == callerDeviceID
		if !targetOwn && !SharedReadable(space) {
			grant, _ := frame.Payload["grant"].(string)
			if grant == "" {
				return DenyAcl
			}
		}
		if device != "" && !IsValidDeviceID(device) {
			return DenyBadOp
		}
		return Allow

	case "recycle.list", "recycle.restore":
		return Allow
	case "recycle.empty":
		if loopback {
			return Allow
		}
		return DenyAcl

	case "import.request":
		old, _ := frame.Payload["old_device"].(string)
		if !IsValidDeviceID(old) || old == callerDeviceID {
			return DenyBadOp
		}
		return Allow
	case "import.pending":
		return Allow
	case "import.grant", "import.reject", "import.grants":
		if loopback {
			return Allow
		}
		return DenyAcl

	case "stats":
		return Allow

	case "sync.hello":
		d, _ := frame.Payload["device"].(string)
		if !IsValidDeviceID(d) || d != callerDeviceID {
			return DenyAcl
		}
		return Allow

	case "sync.cursors", "master.pointer.query", "master.migrate", "master.pointer":
		return Allow

	default:
		return DenyBadOp
	}
}
