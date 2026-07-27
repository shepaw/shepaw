package store

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
	"time"
)

const (
	importDefaultTTL = 24 * time.Hour
)

var grantSpaces = []string{"backups", "attachments"}

type importRequest struct {
	RequestID    string `json:"request_id"`
	OldDevice    string `json:"old_device"`
	NewDevice    string `json:"new_device"`
	RequestedAt  int64  `json:"requested_at"`
	Status       string `json:"status"` // pending | granted | rejected
}

type importGrant struct {
	GrantID   string   `json:"grant_id"`
	OldDevice string   `json:"old_device"`
	NewDevice string   `json:"new_device"`
	Spaces    []string `json:"spaces"`
	IssuedAt  int64    `json:"issued_at"`
	ExpiresAt int64    `json:"expires_at"`
	Revoked   bool     `json:"revoked"`
}

func (g importGrant) expired(now int64) bool {
	return now > g.ExpiresAt
}

func (g importGrant) toMap() map[string]any {
	return map[string]any{
		"grant_id":   g.GrantID,
		"old_device": g.OldDevice,
		"new_device": g.NewDevice,
		"spaces":     g.Spaces,
		"issued_at":  g.IssuedAt,
		"expires_at": g.ExpiresAt,
		"revoked":    g.Revoked,
	}
}

func (r importRequest) toMap() map[string]any {
	return map[string]any{
		"request_id":   r.RequestID,
		"old_device":   r.OldDevice,
		"new_device":   r.NewDevice,
		"requested_at": r.RequestedAt,
		"status":       r.Status,
	}
}

type importAuth struct {
	root string
	mu   sync.Mutex
}

func newImportAuth(root string) *importAuth {
	return &importAuth{root: root}
}

func (a *importAuth) systemPath(name string) string {
	return filepath.Join(a.root, ".system", name)
}

func (a *importAuth) createRequest(oldDevice, newDevice string) (importRequest, bool, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	reqs, err := a.loadRequests()
	if err != nil {
		return importRequest{}, false, err
	}
	for _, r := range reqs {
		if r.OldDevice == oldDevice && r.NewDevice == newDevice && r.Status == "pending" {
			return r, false, nil
		}
	}
	req := importRequest{
		RequestID:   "ir-" + randomID(),
		OldDevice:   oldDevice,
		NewDevice:   newDevice,
		RequestedAt: time.Now().UnixMilli(),
		Status:      "pending",
	}
	reqs = append(reqs, req)
	if err := a.saveRequests(reqs); err != nil {
		return importRequest{}, false, err
	}
	return req, true, nil
}

func (a *importAuth) pendingRequests() ([]importRequest, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	reqs, err := a.loadRequests()
	if err != nil {
		return nil, err
	}
	out := make([]importRequest, 0)
	for _, r := range reqs {
		if r.Status == "pending" {
			out = append(out, r)
		}
	}
	return out, nil
}

func (a *importAuth) grant(requestID string) (importGrant, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	reqs, err := a.loadRequests()
	if err != nil {
		return importGrant{}, err
	}
	var req *importRequest
	for i := range reqs {
		if reqs[i].RequestID == requestID {
			req = &reqs[i]
			break
		}
	}
	if req == nil {
		return importGrant{}, &OpError{Code: "not_found", Msg: "request not found"}
	}
	if req.Status != "pending" {
		return importGrant{}, &OpError{Code: "bad_op", Msg: "request already " + req.Status}
	}
	now := time.Now().UnixMilli()
	g := importGrant{
		GrantID:   "ig-" + randomID(),
		OldDevice: req.OldDevice,
		NewDevice: req.NewDevice,
		Spaces:    append([]string(nil), grantSpaces...),
		IssuedAt:  now,
		ExpiresAt: now + importDefaultTTL.Milliseconds(),
	}
	grants, err := a.loadGrants()
	if err != nil {
		return importGrant{}, err
	}
	grants = append(grants, g)
	if err := a.saveGrants(grants); err != nil {
		return importGrant{}, err
	}
	req.Status = "granted"
	if err := a.saveRequests(reqs); err != nil {
		return importGrant{}, err
	}
	return g, nil
}

func (a *importAuth) reject(requestID string) error {
	a.mu.Lock()
	defer a.mu.Unlock()
	reqs, err := a.loadRequests()
	if err != nil {
		return err
	}
	for i := range reqs {
		if reqs[i].RequestID == requestID {
			reqs[i].Status = "rejected"
		}
	}
	return a.saveRequests(reqs)
}

func (a *importAuth) validate(grantID, oldDevice, newDevice, space string) (bool, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	grants, err := a.loadGrants()
	if err != nil {
		return false, err
	}
	now := time.Now().UnixMilli()
	for _, g := range grants {
		if g.GrantID != grantID || g.OldDevice != oldDevice || g.NewDevice != newDevice {
			continue
		}
		if g.Revoked || g.expired(now) {
			continue
		}
		for _, s := range g.Spaces {
			if s == space {
				return true, nil
			}
		}
	}
	return false, nil
}

func (a *importAuth) saveReceived(g importGrant) error {
	a.mu.Lock()
	defer a.mu.Unlock()
	received, err := a.loadReceived()
	if err != nil {
		return err
	}
	out := make([]importGrant, 0, len(received)+1)
	for _, x := range received {
		if x.GrantID != g.GrantID {
			out = append(out, x)
		}
	}
	out = append(out, g)
	return a.saveJSON(a.systemPath("import_received.json"), out)
}

func (a *importAuth) issuedGrants() ([]importGrant, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	grants, err := a.loadGrants()
	if err != nil {
		return nil, err
	}
	now := time.Now().UnixMilli()
	out := make([]importGrant, 0)
	for _, g := range grants {
		if !g.Revoked && !g.expired(now) {
			out = append(out, g)
		}
	}
	return out, nil
}

func (a *importAuth) receivedGrants() ([]importGrant, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	grants, err := a.loadReceived()
	if err != nil {
		return nil, err
	}
	now := time.Now().UnixMilli()
	out := make([]importGrant, 0)
	for _, g := range grants {
		if !g.Revoked && !g.expired(now) {
			out = append(out, g)
		}
	}
	return out, nil
}

func (a *importAuth) loadRequests() ([]importRequest, error) {
	var out []importRequest
	if err := a.loadJSON(a.systemPath("import_requests.json"), &out); err != nil {
		return nil, err
	}
	if out == nil {
		out = []importRequest{}
	}
	return out, nil
}

func (a *importAuth) saveRequests(reqs []importRequest) error {
	return a.saveJSON(a.systemPath("import_requests.json"), reqs)
}

func (a *importAuth) loadGrants() ([]importGrant, error) {
	var out []importGrant
	if err := a.loadJSON(a.systemPath("import_grants.json"), &out); err != nil {
		return nil, err
	}
	if out == nil {
		out = []importGrant{}
	}
	return out, nil
}

func (a *importAuth) saveGrants(grants []importGrant) error {
	return a.saveJSON(a.systemPath("import_grants.json"), grants)
}

func (a *importAuth) loadReceived() ([]importGrant, error) {
	var out []importGrant
	if err := a.loadJSON(a.systemPath("import_received.json"), &out); err != nil {
		return nil, err
	}
	if out == nil {
		out = []importGrant{}
	}
	return out, nil
}

func (a *importAuth) loadJSON(path string, dest any) error {
	raw, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	return json.Unmarshal(raw, dest)
}

func (a *importAuth) saveJSON(path string, data any) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	raw, err := json.Marshal(data)
	if err != nil {
		return err
	}
	tmp := path + "." + randomID() + ".tmp"
	if err := os.WriteFile(tmp, raw, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func randomID() string {
	var b [8]byte
	_, _ = rand.Read(b[:])
	return hex.EncodeToString(b[:])
}
