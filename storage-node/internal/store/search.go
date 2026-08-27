package store

import (
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/shepaw/storage-node/internal/protocol"
)

func (l *Local) search(frame protocol.Frame, caller string) (map[string]any, error) {
	q, _ := frame.Payload["q"].(string)
	q = strings.TrimSpace(strings.ToLower(q))
	if q == "" {
		return nil, &OpError{Code: "bad_op", Msg: "empty query"}
	}
	space, _ := frame.Payload["space"].(string)
	if space != "" {
		if _, known := l.spaceVis(space); !known {
			return nil, &OpError{Code: "bad_op", Msg: "unknown space"}
		}
	}
	state, _ := frame.Payload["state"].(string)
	if state != "" && state != "committed" && state != "published" {
		return map[string]any{"query": q, "total": 0, "results": []any{}}, nil
	}
	device, _ := frame.Payload["device"].(string)
	limit := int(num(frame.Payload["limit"]))
	if limit <= 0 {
		limit = 50
	}
	if limit > 200 {
		limit = 200
	}
	tokens := strings.Fields(q)
	devices := []string{}
	if device != "" {
		devices = []string{device}
	} else {
		ents, _ := os.ReadDir(l.Root)
		for _, e := range ents {
			if e.IsDir() && protocol.IsValidDeviceID(e.Name()) {
				devices = append(devices, e.Name())
			}
		}
	}
	spaces := []string{}
	if space != "" {
		spaces = []string{space}
	} else {
		for _, sp := range protocol.BuiltinSpaces() {
			if sp != "backups" {
				spaces = append(spaces, sp)
			}
		}
		for name := range l.loadCustomSpaces() {
			spaces = append(spaces, name)
		}
	}
	type hit struct {
		row   map[string]any
		score int
	}
	hits := []hit{}
	scanned := 0
	const scanLimit = 5000
	for _, dev := range devices {
		for _, sp := range spaces {
			if scanned >= scanLimit {
				break
			}
			listed, err := l.list(protocol.Frame{
				Payload: map[string]any{"space": sp, "device": dev, "limit": scanLimit - scanned, "hash": false},
			}, caller)
			if err != nil {
				continue
			}
			entries, _ := listed["entries"].([]map[string]any)
			if entries == nil {
				if arr, ok := listed["entries"].([]any); ok {
					for _, item := range arr {
						if m, ok := item.(map[string]any); ok {
							entries = append(entries, m)
						}
					}
				}
			}
			scanned += len(entries)
			for _, e := range entries {
				path, _ := e["path"].(string)
				if path == "" {
					continue
				}
				score := 0
				ok := true
				for _, tok := range tokens {
					s := searchPathScore(path, tok)
					if s <= 0 {
						ok = false
						break
					}
					score += s
				}
				snippet := path
				if !ok {
					sn, hitContent := peekText(filepath.Join(l.Root, dev, sp, filepath.FromSlash(path)), tokens)
					if !hitContent {
						continue
					}
					snippet = sn
					score = 40
				}
				size := int64(num(e["size"]))
				sha, _ := e["sha256"].(string)
				hits = append(hits, hit{row: map[string]any{
					"uri": "store://" + sp + "/" + dev + "/" + path,
					"space": sp, "device": dev, "path": path,
					"sha256": sha, "size": size, "state": "committed",
					"snippet": snippet, "score": float64(score),
				}, score: score})
			}
		}
	}
	sort.Slice(hits, func(i, j int) bool { return hits[i].score > hits[j].score })
	if len(hits) > limit {
		hits = hits[:limit]
	}
	results := make([]map[string]any, 0, len(hits))
	for _, h := range hits {
		results = append(results, h.row)
	}
	return map[string]any{"query": q, "total": len(results), "results": results}, nil
}

func searchPathScore(path, needle string) int {
	name := strings.ToLower(filepath.Base(path))
	full := strings.ToLower(path)
	n := strings.ToLower(needle)
	if name == n {
		return 500
	}
	if strings.HasPrefix(name, n) {
		return 400
	}
	if strings.Contains(name, n) {
		return 300
	}
	if strings.Contains(full, n) {
		return 100
	}
	return 0
}

func peekText(abs string, tokens []string) (string, bool) {
	ext := strings.ToLower(filepath.Ext(abs))
	switch ext {
	case ".md", ".txt", ".json", ".csv", ".yaml", ".yml", ".log", ".arb", ".xml", ".html", ".dart", ".py", ".go", ".js", ".ts":
	default:
		return "", false
	}
	raw, err := os.ReadFile(abs)
	if err != nil || len(raw) == 0 || len(raw) > 256*1024 {
		return "", false
	}
	text := strings.ToLower(string(raw))
	if len(text) > 640 {
		text = text[:640]
	}
	for _, tok := range tokens {
		if !strings.Contains(text, strings.ToLower(tok)) {
			return "", false
		}
	}
	return strings.TrimSpace(text), true
}
