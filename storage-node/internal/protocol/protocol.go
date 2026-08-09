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
	Allow         AclVerdict = "allow"
	DenyUntrusted AclVerdict = "denyUntrusted"
	DenyAcl       AclVerdict = "denyAcl"
	DenyBadOp     AclVerdict = "denyBadOp"
	DenyBadPath   AclVerdict = "denyBadPath"
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

func (f Frame) Path() string {
	if v, ok := f.Payload["path"].(string); ok {
		return v
	}
	return ""
}

func IsValidDeviceID(device string) bool {
	return deviceIDRe.MatchString(device)
}

// BuiltinSpaces mirrors Dart StoreSpace.all (new + legacy).
func BuiltinSpaces() []string {
	return []string{
		"workspaces", "runtime", "files", "public", "backups",
		"artifacts", "attachments",
	}
}

func IsValidSpace(s string) bool {
	for _, sp := range BuiltinSpaces() {
		if s == sp {
			return true
		}
	}
	return false
}

// SharedReadable: owner 默认可跨端读（不含 private runtime）。
func SharedReadable(s string) bool {
	switch s {
	case "workspaces", "files", "public", "artifacts":
		return true
	default:
		return false
	}
}

// OwnerCrossWritable: 仅 workspaces 允许 owner 跨 device 写。
func OwnerCrossWritable(s string) bool {
	return s == "workspaces"
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
	// Leading backslash (Windows absolute / UNC-ish) is not a relative store path.
	if strings.HasPrefix(raw, `\`) {
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

// ShareAllowedFunc reports whether cross-device access to space/path is allowed.
// path may be empty for list root.
type ShareAllowedFunc func(space, path string) bool

func friendDeniedOp(op string) bool {
	switch op {
	case "recycle.list", "recycle.restore", "recycle.empty",
		"import.request", "import.pending", "import.grant", "import.reject", "import.grants",
		"sync.hello", "sync.cursors", "master.pointer", "master.pointer.query", "master.migrate",
		"space.declare", "space.list", "stats", "search", "events.list",
		"handoff.create", "handoff.ack":
		return true
	default:
		return false
	}
}

func crossSharedAccess(trustLevel, space, path string, shareAllowed ShareAllowedFunc) AclVerdict {
	if shareAllowed != nil {
		if shareAllowed(space, path) {
			return Allow
		}
		return DenyAcl
	}
	if trustLevel == TrustOwner {
		return Allow
	}
	return DenyAcl
}

// CheckACL mirrors Dart checkStoreAcl (M2–M4 ops used by fixtures).
func CheckACL(frame Frame, callerDeviceID, trustLevel string, loopback bool) AclVerdict {
	return CheckACLWith(frame, callerDeviceID, trustLevel, loopback, nil)
}

// CheckACLWith adds optional share allowlist for cross-device shared spaces.
func CheckACLWith(frame Frame, callerDeviceID, trustLevel string, loopback bool, shareAllowed ShareAllowedFunc) AclVerdict {
	isOwner := trustLevel == TrustOwner
	if !isOwner && friendDeniedOp(frame.Op) {
		return DenyUntrusted
	}

	space := frame.Space()
	device := frame.Device()

	switch frame.Op {
	case "write.begin", "write.chunk", "commit", "handoff.create":
		if space != "" && !IsValidSpace(space) {
			return DenyBadOp
		}
		if frame.Op == "write.begin" && space == "" {
			return DenyBadOp
		}
		if device != "" && device != callerDeviceID {
			// workspaces：owner 可写任意 owner 设备目录
			if OwnerCrossWritable(space) && isOwner && IsValidDeviceID(device) {
				return Allow
			}
			return DenyAcl
		}
		return Allow

	case "delete", "handoff.ack":
		if space == "" || !IsValidSpace(space) {
			return DenyBadOp
		}
		targetOwn := device == "" || device == callerDeviceID
		if !targetOwn {
			if !SharedReadable(space) {
				return DenyAcl
			}
			if v := crossSharedAccess(trustLevel, space, frame.Path(), shareAllowed); v != Allow {
				return v
			}
		}
		if device != "" && !IsValidDeviceID(device) {
			return DenyBadOp
		}
		return Allow

	case "list", "meta", "read", "versions.list", "versions.read", "manifest", "artifact.state":
		if space == "" || !IsValidSpace(space) {
			return DenyBadOp
		}
		targetOwn := device == "" || device == callerDeviceID
		if !targetOwn && SharedReadable(space) {
			path := frame.Path()
			if v := crossSharedAccess(trustLevel, space, path, shareAllowed); v != Allow {
				return v
			}
		} else if !targetOwn && !SharedReadable(space) {
			seed, _ := frame.Payload["seed"].(bool)
			if seed {
				if !isOwner {
					return DenyUntrusted
				}
				if device != "" && !IsValidDeviceID(device) {
					return DenyBadOp
				}
				return Allow
			}
			grant, _ := frame.Payload["grant"].(string)
			if grant == "" {
				return DenyAcl
			}
			if !isOwner {
				return DenyUntrusted
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

	case "stats", "space.list", "search", "events.list":
		return Allow
	case "space.declare":
		if loopback {
			return Allow
		}
		return DenyAcl

	case "sync.hello":
		d, _ := frame.Payload["device"].(string)
		if !IsValidDeviceID(d) || d != callerDeviceID {
			return DenyAcl
		}
		return Allow

	case "sync.cursors", "master.pointer.query", "master.migrate", "master.pointer":
		return Allow

	case "share.announce":
		return Allow

	default:
		return DenyBadOp
	}
}
