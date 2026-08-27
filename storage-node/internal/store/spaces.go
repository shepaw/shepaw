package store

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"

	"github.com/shepaw/storage-node/internal/protocol"
)

type spaceProfile struct {
	Name        string `json:"name"`
	Visibility  string `json:"visibility"`
	Encryption  string `json:"encryption"`
	Retention   string `json:"retention"`
	ImportGrant string `json:"import_grant"`
	Builtin     bool   `json:"builtin"`
}

func builtinSpaceProfiles() []spaceProfile {
	return []spaceProfile{
		{Name: "workspaces", Visibility: "shared", Encryption: "none", Retention: "none", ImportGrant: "allowed", Builtin: true},
		{Name: "runtime", Visibility: "private", Encryption: "none", Retention: "none", ImportGrant: "allowed", Builtin: true},
		{Name: "files", Visibility: "shared", Encryption: "none", Retention: "none", ImportGrant: "allowed", Builtin: true},
		{Name: "public", Visibility: "shared", Encryption: "none", Retention: "none", ImportGrant: "allowed", Builtin: true},
		{Name: "backups", Visibility: "private", Encryption: "client", Retention: "gfs", ImportGrant: "allowed", Builtin: true},
		{Name: "cognition", Visibility: "private", Encryption: "none", Retention: "none", ImportGrant: "allowed", Builtin: true},
		{Name: "memory", Visibility: "private", Encryption: "none", Retention: "none", ImportGrant: "allowed", Builtin: true},
		{Name: "artifacts", Visibility: "shared", Encryption: "none", Retention: "none", ImportGrant: "allowed", Builtin: true},
		{Name: "attachments", Visibility: "private", Encryption: "client", Retention: "none", ImportGrant: "allowed", Builtin: true},
	}
}

func (l *Local) spacesPath() string {
	return filepath.Join(l.Root, ".system", "spaces.json")
}

func (l *Local) loadCustomSpaces() map[string]spaceProfile {
	out := map[string]spaceProfile{}
	raw, err := os.ReadFile(l.spacesPath())
	if err != nil {
		return out
	}
	var doc struct {
		Spaces []spaceProfile `json:"spaces"`
	}
	if json.Unmarshal(raw, &doc) != nil {
		return out
	}
	for _, p := range doc.Spaces {
		if p.Name == "" || protocol.IsReservedDeclareName(p.Name) {
			continue
		}
		out[p.Name] = p
	}
	return out
}

func (l *Local) spaceVis(space string) (shared, known bool) {
	if protocol.IsValidSpace(space) {
		return protocol.SharedReadable(space), true
	}
	p, ok := l.loadCustomSpaces()[space]
	if !ok {
		return false, false
	}
	return p.Visibility == "shared", true
}

func (l *Local) spaceList(_ protocol.Frame) (map[string]any, error) {
	custom := l.loadCustomSpaces()
	names := make([]string, 0, len(custom))
	for n := range custom {
		names = append(names, n)
	}
	sort.Strings(names)
	spaces := builtinSpaceProfiles()
	for _, n := range names {
		p := custom[n]
		p.Builtin = false
		spaces = append(spaces, p)
	}
	out := make([]map[string]any, 0, len(spaces))
	for _, p := range spaces {
		out = append(out, map[string]any{
			"name": p.Name, "visibility": p.Visibility, "encryption": p.Encryption,
			"retention": p.Retention, "import_grant": p.ImportGrant, "builtin": p.Builtin,
		})
	}
	return map[string]any{"spaces": out}, nil
}

func (l *Local) spaceDeclare(frame protocol.Frame, caller string) (map[string]any, error) {
	name, _ := frame.Payload["name"].(string)
	if !protocol.IsValidSpaceSyntax(name) {
		return nil, &OpError{Code: "bad_op", Msg: "invalid space name"}
	}
	if protocol.IsReservedDeclareName(name) {
		return nil, &OpError{Code: "bad_op", Msg: "reserved space name"}
	}
	vis, _ := frame.Payload["visibility"].(string)
	if vis == "" {
		vis = "private"
	}
	if vis != "shared" && vis != "private" {
		return nil, &OpError{Code: "bad_op", Msg: "invalid visibility"}
	}
	enc, _ := frame.Payload["encryption"].(string)
	if enc == "" {
		enc = "none"
	}
	if enc != "client" && enc != "none" {
		return nil, &OpError{Code: "bad_op", Msg: "invalid encryption"}
	}
	ret, _ := frame.Payload["retention"].(string)
	if ret == "" {
		ret = "none"
	}
	if ret != "keep_last" && ret != "gfs" && ret != "none" {
		return nil, &OpError{Code: "bad_op", Msg: "invalid retention"}
	}
	grant, _ := frame.Payload["import_grant"].(string)
	if grant == "" {
		grant = "allowed"
	}
	if grant != "allowed" && grant != "denied" {
		return nil, &OpError{Code: "bad_op", Msg: "invalid import_grant"}
	}
	profile := spaceProfile{
		Name: name, Visibility: vis, Encryption: enc, Retention: ret, ImportGrant: grant,
	}
	custom := l.loadCustomSpaces()
	custom[name] = profile
	list := make([]spaceProfile, 0, len(custom))
	for _, p := range custom {
		list = append(list, p)
	}
	raw, _ := json.Marshal(map[string]any{"spaces": list})
	if err := os.MkdirAll(filepath.Dir(l.spacesPath()), 0o755); err != nil {
		return nil, err
	}
	if err := os.WriteFile(l.spacesPath(), raw, 0o644); err != nil {
		return nil, err
	}
	_ = os.MkdirAll(filepath.Join(l.Root, caller, name), 0o755)
	return map[string]any{"space": map[string]any{
		"name": name, "visibility": vis, "encryption": enc,
		"retention": ret, "import_grant": grant, "builtin": false,
	}}, nil
}
