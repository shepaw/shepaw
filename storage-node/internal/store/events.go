package store

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"time"

	"github.com/shepaw/storage-node/internal/protocol"
)

func (l *Local) eventsPath() string {
	return filepath.Join(l.Root, ".system", "events.jsonl")
}

func (l *Local) eventsSeqPath() string {
	return filepath.Join(l.Root, ".system", "events.seq")
}

func (l *Local) latestEventSeq() int64 {
	raw, err := os.ReadFile(l.eventsSeqPath())
	if err != nil {
		return 0
	}
	n, _ := strconv.ParseInt(string(raw), 10, 64)
	return n
}

func (l *Local) appendEvent(kind, device, space, path string, detail map[string]any) {
	l.mu.Lock()
	defer l.mu.Unlock()
	seq := l.latestEventSeq() + 1
	ev := map[string]any{
		"seq": seq, "kind": kind, "device": device, "space": space, "path": path,
		"uri": "store://" + space + "/" + device + "/" + path,
		"ts_ms": time.Now().UnixMilli(),
	}
	if detail != nil {
		ev["detail"] = detail
	}
	raw, _ := json.Marshal(ev)
	_ = os.MkdirAll(filepath.Dir(l.eventsPath()), 0o755)
	f, err := os.OpenFile(l.eventsPath(), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return
	}
	_, _ = f.Write(append(raw, '\n'))
	_ = f.Close()
	_ = os.WriteFile(l.eventsSeqPath(), []byte(strconv.FormatInt(seq, 10)), 0o644)
}

func (l *Local) eventsList(frame protocol.Frame) (map[string]any, error) {
	since := int64(num(frame.Payload["since"]))
	limit := int(num(frame.Payload["limit"]))
	if limit <= 0 {
		limit = 50
	}
	if limit > 200 {
		limit = 200
	}
	kind, _ := frame.Payload["kind"].(string)
	latest := l.latestEventSeq()
	out := []map[string]any{}
	f, err := os.Open(l.eventsPath())
	if err != nil {
		return map[string]any{"events": out, "latest_seq": latest}, nil
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		if len(out) >= limit {
			break
		}
		line := sc.Bytes()
		if len(line) == 0 {
			continue
		}
		var ev map[string]any
		if json.Unmarshal(line, &ev) != nil {
			continue
		}
		seq := int64(num(ev["seq"]))
		if seq <= since {
			continue
		}
		if kind != "" {
			k, _ := ev["kind"].(string)
			if k != kind {
				continue
			}
		}
		out = append(out, ev)
	}
	return map[string]any{"events": out, "latest_seq": latest}, nil
}
