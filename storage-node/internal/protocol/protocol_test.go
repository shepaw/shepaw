package protocol_test

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/shepaw/storage-node/internal/protocol"
)

func fixturesDir(t *testing.T) string {
	t.Helper()
	// From storage-node/internal/protocol → repo root docs/storage_fixtures
	candidates := []string{
		filepath.Join("..", "..", "..", "docs", "storage_fixtures"),
		filepath.Join("..", "..", "docs", "storage_fixtures"),
		filepath.Join("docs", "storage_fixtures"),
	}
	for _, c := range candidates {
		if st, err := os.Stat(c); err == nil && st.IsDir() {
			abs, _ := filepath.Abs(c)
			return abs
		}
	}
	wd, _ := os.Getwd()
	t.Fatalf("docs/storage_fixtures not found (cwd=%s)", wd)
	return ""
}

func TestPathAttacksFixture(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join(fixturesDir(t), "path_attacks.json"))
	if err != nil {
		t.Fatal(err)
	}
	var doc struct {
		Attacks []string   `json:"attacks"`
		OK      [][]string `json:"ok"`
	}
	if err := json.Unmarshal(raw, &doc); err != nil {
		t.Fatal(err)
	}
	for _, p := range doc.Attacks {
		if _, err := protocol.NormalizePath(p); err == nil {
			t.Fatalf("expected reject: %q", p)
		}
	}
	for _, row := range doc.OK {
		got, err := protocol.NormalizePath(row[0])
		if err != nil {
			t.Fatalf("normalize %q: %v", row[0], err)
		}
		if got != row[1] {
			t.Fatalf("normalize %q: got %q want %q", row[0], got, row[1])
		}
	}
}

func TestACLFixture(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join(fixturesDir(t), "acl_cases.json"))
	if err != nil {
		t.Fatal(err)
	}
	var doc struct {
		Caller string `json:"caller"`
		Cases  []struct {
			Name     string         `json:"name"`
			Op       string         `json:"op"`
			Trust    string         `json:"trust"`
			Loopback bool           `json:"loopback"`
			Payload  map[string]any `json:"payload"`
			Expect   string         `json:"expect"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(raw, &doc); err != nil {
		t.Fatal(err)
	}
	for _, c := range doc.Cases {
		v := protocol.CheckACL(protocol.Frame{Op: c.Op, Payload: c.Payload}, doc.Caller, c.Trust, c.Loopback)
		if string(v) != c.Expect {
			t.Fatalf("%s: got %s want %s", c.Name, v, c.Expect)
		}
	}
}

func TestFriendShareIsReadOnly(t *testing.T) {
	allowDocs := func(space, path string) bool {
		if space != "files" {
			return false
		}
		return path == "" || path == "docs" || strings.HasPrefix(path, "docs/")
	}
	const caller = "aaaaaaaaaaaaaaaa"
	const other = "bbbbbbbbbbbbbbbb"
	read := protocol.CheckACLWith(protocol.Frame{Op: "read", Payload: map[string]any{
		"space": "files", "device": other, "path": "docs/a.txt",
	}}, caller, protocol.TrustFriend, false, allowDocs)
	if read != protocol.Allow {
		t.Fatalf("read: %s", read)
	}
	del := protocol.CheckACLWith(protocol.Frame{Op: "delete", Payload: map[string]any{
		"space": "files", "device": other, "path": "docs/a.txt",
	}}, caller, protocol.TrustFriend, false, allowDocs)
	if del != protocol.DenyAcl {
		t.Fatalf("delete: %s", del)
	}
}

func TestSpaceProfileFixture(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join(fixturesDir(t), "space_profile_cases.json"))
	if err != nil {
		t.Fatal(err)
	}
	var doc struct {
		Caller string            `json:"caller"`
		Known  map[string]string `json:"known"`
		Cases  []struct {
			Name     string         `json:"name"`
			Op       string         `json:"op"`
			Trust    string         `json:"trust"`
			Loopback bool           `json:"loopback"`
			Payload  map[string]any `json:"payload"`
			Expect   string         `json:"expect"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(raw, &doc); err != nil {
		t.Fatal(err)
	}
	vis := func(space string) (bool, bool) {
		v, ok := doc.Known[space]
		if !ok {
			return false, false
		}
		return v == "shared", true
	}
	for _, c := range doc.Cases {
		v := protocol.CheckACLEx(protocol.Frame{Op: c.Op, Payload: c.Payload}, doc.Caller, c.Trust, c.Loopback, nil, vis)
		if string(v) != c.Expect {
			t.Fatalf("%s: got %s want %s", c.Name, v, c.Expect)
		}
	}
}
