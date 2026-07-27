package peer

import (
	"encoding/json"
	"sync"

	"github.com/gorilla/websocket"
	"github.com/shepaw/storage-node/internal/noise"
)

// liveSession is one Noise-encrypted peer WS transport.
type liveSession struct {
	fp      string
	conn    *websocket.Conn
	sess    *noise.Session
	writeMu *sync.Mutex
}

// SessionRegistry tracks active /peer/ws transports for push fanout
// (master.pointer after migrate, future import.grant, etc.).
type SessionRegistry struct {
	mu   sync.Mutex
	byFP map[string]*liveSession
}

func NewSessionRegistry() *SessionRegistry {
	return &SessionRegistry{byFP: map[string]*liveSession{}}
}

// Add registers or replaces the live session for fp.
func (r *SessionRegistry) Add(fp string, conn *websocket.Conn, sess *noise.Session, writeMu *sync.Mutex) {
	if r == nil || fp == "" || conn == nil || sess == nil || writeMu == nil {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	r.byFP[fp] = &liveSession{fp: fp, conn: conn, sess: sess, writeMu: writeMu}
}

// Remove drops the session only if conn still matches (reconnect-safe).
func (r *SessionRegistry) Remove(fp string, conn *websocket.Conn) {
	if r == nil {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	cur, ok := r.byFP[fp]
	if !ok || cur.conn != conn {
		return
	}
	delete(r.byFP, fp)
}

// Len returns the number of registered sessions.
func (r *SessionRegistry) Len() int {
	if r == nil {
		return 0
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.byFP)
}

// FanoutJSON encrypts and sends a store control JSON object to every live session.
// Returns the number of successful writes.
func (r *SessionRegistry) FanoutJSON(plain map[string]any) int {
	if r == nil || plain == nil {
		return 0
	}
	raw, err := json.Marshal(plain)
	if err != nil {
		return 0
	}
	r.mu.Lock()
	sessions := make([]*liveSession, 0, len(r.byFP))
	for _, ls := range r.byFP {
		sessions = append(sessions, ls)
	}
	r.mu.Unlock()

	n := 0
	for _, ls := range sessions {
		ct, err := ls.sess.Encrypt(raw)
		if err != nil {
			continue
		}
		enc, err := noise.EncodeFrame(noise.Frame{Type: noise.FrameData, Payload: ct})
		if err != nil {
			continue
		}
		ls.writeMu.Lock()
		err = ls.conn.WriteMessage(websocket.TextMessage, []byte(enc))
		ls.writeMu.Unlock()
		if err == nil {
			n++
		}
	}
	return n
}

// FanoutMasterPointer sends a no-req_id master.pointer notification to all live sessions.
func (r *SessionRegistry) FanoutMasterPointer(master string, epoch int64, fromDevice string) int {
	return r.FanoutJSON(map[string]any{
		"type": "store", "ns": "store", "op": "master.pointer", "v": 1,
		"master": master, "epoch": epoch, "from": fromDevice,
	})
}

// SendJSON encrypts and sends a store control JSON object to one live session by fingerprint.
func (r *SessionRegistry) SendJSON(fp string, plain map[string]any) bool {
	if r == nil || fp == "" || plain == nil {
		return false
	}
	raw, err := json.Marshal(plain)
	if err != nil {
		return false
	}
	r.mu.Lock()
	ls := r.byFP[fp]
	r.mu.Unlock()
	if ls == nil {
		return false
	}
	ct, err := ls.sess.Encrypt(raw)
	if err != nil {
		return false
	}
	enc, err := noise.EncodeFrame(noise.Frame{Type: noise.FrameData, Payload: ct})
	if err != nil {
		return false
	}
	ls.writeMu.Lock()
	err = ls.conn.WriteMessage(websocket.TextMessage, []byte(enc))
	ls.writeMu.Unlock()
	return err == nil
}

// PushImportGrant sends a no-req_id import.grant notification to the requester (new_device).
// Payload shape matches Dart StoreService._pushGrantToRequester.
func (r *SessionRegistry) PushImportGrant(grant map[string]any) bool {
	if grant == nil {
		return false
	}
	newDevice, _ := grant["new_device"].(string)
	if newDevice == "" {
		return false
	}
	return r.SendJSON(newDevice, map[string]any{
		"type": "store", "ns": "store", "op": "import.grant", "v": 1,
		"grant_id":   grant["grant_id"],
		"old_device": grant["old_device"],
		"spaces":     grant["spaces"],
		"issued_at":  grant["issued_at"],
		"expires_at": grant["expires_at"],
	})
}
