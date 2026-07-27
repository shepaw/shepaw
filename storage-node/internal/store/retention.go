package store

import (
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

// applyRetention runs optional commit.retention after a successful promote.
// Policies: keep_last | gfs. Scope = top-level dirs under <device>/<space>/.
func (l *Local) applyRetention(device, space string, raw any) {
	m, ok := raw.(map[string]any)
	if !ok || m == nil {
		return
	}
	policy, _ := m["policy"].(string)
	include, _ := m["include_prefix"].(string)
	exclude, _ := m["exclude_prefix"].(string)
	entries, err := listTopLevel(filepath.Join(l.Root, device, space))
	if err != nil {
		return
	}
	filtered := make([]topEntry, 0, len(entries))
	for _, e := range entries {
		if include != "" && !strings.HasPrefix(e.id, include) {
			continue
		}
		if exclude != "" && strings.HasPrefix(e.id, exclude) {
			continue
		}
		filtered = append(filtered, e)
	}
	var toDelete []string
	switch policy {
	case "keep_last":
		keep := intFrom(m["keep"], -1)
		if keep < 0 {
			return
		}
		sort.Slice(filtered, func(i, j int) bool {
			return filtered[i].mtimeMs > filtered[j].mtimeMs
		})
		if len(filtered) > keep {
			for _, e := range filtered[keep:] {
				toDelete = append(toDelete, e.id)
			}
		}
	case "gfs":
		daily := intFrom(m["daily"], 7)
		weekly := intFrom(m["weekly"], 28)
		monthly := intFrom(m["monthly"], 12)
		toDelete = selectGfsDelete(filtered, daily, weekly, monthly)
	default:
		return
	}
	for _, id := range toDelete {
		_, _ = l.moveToRecycle(device, space, id)
	}
}

type topEntry struct {
	id      string
	mtimeMs int64
}

func listTopLevel(dir string) ([]topEntry, error) {
	ents, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	out := make([]topEntry, 0, len(ents))
	for _, e := range ents {
		if !e.IsDir() || strings.HasPrefix(e.Name(), ".") {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		out = append(out, topEntry{
			id:      e.Name(),
			mtimeMs: info.ModTime().UnixMilli(),
		})
	}
	return out, nil
}

func intFrom(v any, def int) int {
	switch n := v.(type) {
	case float64:
		return int(n)
	case int:
		return n
	case int64:
		return int(n)
	default:
		return def
	}
}

// selectGfsDelete mirrors Dart gfs_retention.selectGfs deleteIds.
func selectGfsDelete(entries []topEntry, daily, weekly, monthly int) []string {
	if len(entries) == 0 {
		return nil
	}
	sorted := append([]topEntry(nil), entries...)
	sort.Slice(sorted, func(i, j int) bool {
		return sorted[i].mtimeMs > sorted[j].mtimeMs
	})
	now := time.Now()
	keep := map[string]struct{}{}
	seenDays := map[string]struct{}{}
	seenWeeks := map[string]struct{}{}
	seenMonths := map[int]struct{}{}

	for _, e := range sorted {
		t := time.UnixMilli(e.mtimeMs).Local()
		dayKey := t.Format("2006-1-2")
		year, week := t.ISOWeek()
		weekKey := strconv.Itoa(year) + "-W" + strconv.Itoa(week)
		monthKey := t.Year()*12 + int(t.Month())

		dayDiff := int(dateOnly(now).Sub(dateOnly(t)).Hours() / 24)
		weekStartNow := dateOnly(now).AddDate(0, 0, -((int(now.Weekday())+6)%7))
		weekStartT := dateOnly(t).AddDate(0, 0, -((int(t.Weekday())+6)%7))
		weekStartDiff := int(weekStartNow.Sub(weekStartT).Hours() / 24)
		monthDiff := (now.Year()*12 + int(now.Month())) - monthKey

		if dayDiff < daily {
			if _, ok := seenDays[dayKey]; !ok {
				seenDays[dayKey] = struct{}{}
				keep[e.id] = struct{}{}
			}
		}
		if weekStartDiff < weekly {
			if _, ok := seenWeeks[weekKey]; !ok {
				seenWeeks[weekKey] = struct{}{}
				keep[e.id] = struct{}{}
			}
		}
		if monthDiff < monthly {
			if _, ok := seenMonths[monthKey]; !ok {
				seenMonths[monthKey] = struct{}{}
				keep[e.id] = struct{}{}
			}
		}
	}
	var del []string
	for _, e := range sorted {
		if _, ok := keep[e.id]; !ok {
			del = append(del, e.id)
		}
	}
	return del
}

func dateOnly(t time.Time) time.Time {
	return time.Date(t.Year(), t.Month(), t.Day(), 0, 0, 0, 0, t.Location())
}
