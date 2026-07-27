package peer

import (
	"encoding/json"
	"fmt"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"
	"github.com/shepaw/storage-node/internal/noise"
)

// liveSession is one Noise-encrypted peer WS transport.
type liveSession struct {
	fp       string
	conn     *websocket.Conn
	sess     *noise.Session
	writeMu  *sync.Mutex
	pending  map[string]chan map[string]any
	pendingM sync.Mutex
}

// encryptWrite serializes Noise Encrypt + WS write (cipher nonce is not concurrent-safe).
func (ls *liveSession) encryptWrite(plain []byte) error {
	ls.writeMu.Lock()
	defer ls.writeMu.Unlock()
	ct, err := ls.sess.Encrypt(plain)
	if err != nil {
		return err
	}
	enc, err := noise.EncodeFrame(noise.Frame{Type: noise.FrameData, Payload: ct})
	if err != nil {
		return err
	}
	return ls.conn.WriteMessage(websocket.TextMessage, []byte(enc))
}

// SessionRegistry tracks active /peer/ws transports for push fanout
// and outbound store RPCs (migrate seed, etc.).
type SessionRegistry struct {
	mu   sync.Mutex
	byFP map[string]*liveSession
	seq  atomic.Uint64
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
	r.byFP[fp] = &liveSession{
		fp:      fp,
		conn:    conn,
		sess:    sess,
		writeMu: writeMu,
		pending: map[string]chan map[string]any{},
	}
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
	cur.pendingM.Lock()
	for id, ch := range cur.pending {
		close(ch)
		delete(cur.pending, id)
	}
	cur.pendingM.Unlock()
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

// Has reports whether a live session exists for device fingerprint.
func (r *SessionRegistry) Has(deviceID string) bool {
	if r == nil || deviceID == "" {
		return false
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	_, ok := r.byFP[deviceID]
	return ok
}

func (r *SessionRegistry) get(fp string) *liveSession {
	if r == nil {
		return nil
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.byFP[fp]
}

// DeliverReply completes a pending CallStore waiter. Returns true if delivered.
func (r *SessionRegistry) DeliverReply(fp, reqID string, msg map[string]any) bool {
	ls := r.get(fp)
	if ls == nil || reqID == "" {
		return false
	}
	ls.pendingM.Lock()
	ch := ls.pending[reqID]
	if ch != nil {
		delete(ls.pending, reqID)
	}
	ls.pendingM.Unlock()
	if ch == nil {
		return false
	}
	select {
	case ch <- msg:
	default:
	}
	return true
}

// Call invokes a store op on a live peer and waits for result/error (PeerRPC).
func (r *SessionRegistry) Call(deviceID, op string, payload map[string]any) (map[string]any, error) {
	return r.CallStore(deviceID, op, payload, 20*time.Second)
}

// CallStore sends a flat Dart-style store frame and waits for the matching reply.
func (r *SessionRegistry) CallStore(fp, op string, payload map[string]any, timeout time.Duration) (map[string]any, error) {
	ls := r.get(fp)
	if ls == nil {
		return nil, fmt.Errorf("peer offline: %s", fp)
	}
	if payload == nil {
		payload = map[string]any{}
	}
	reqID := fmt.Sprintf("rpc-%d", r.seq.Add(1))
	frame := map[string]any{
		"type": "store", "ns": "store", "op": op, "v": 1, "req_id": reqID,
	}
	for k, v := range payload {
		frame[k] = v
	}
	raw, err := json.Marshal(frame)
	if err != nil {
		return nil, err
	}
	ch := make(chan map[string]any, 1)
	ls.pendingM.Lock()
	ls.pending[reqID] = ch
	ls.pendingM.Unlock()
	defer func() {
		ls.pendingM.Lock()
		delete(ls.pending, reqID)
		ls.pendingM.Unlock()
	}()

	if err := ls.encryptWrite(raw); err != nil {
		return nil, err
	}

	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case msg, ok := <-ch:
		if !ok || msg == nil {
			return nil, fmt.Errorf("session closed")
		}
		if msg["op"] == "error" {
			code, _ := msg["code"].(string)
			m, _ := msg["message"].(string)
			if code == "" {
				code = "internal"
			}
			return nil, fmt.Errorf("%s: %s", code, m)
		}
		if data, ok := msg["data"].(map[string]any); ok {
			return data, nil
		}
		return map[string]any{}, nil
	case <-timer.C:
		return nil, fmt.Errorf("timeout calling %s on %s", op, fp)
	}
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
		if err := ls.encryptWrite(raw); err == nil {
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
	ls := r.get(fp)
	if ls == nil {
		return false
	}
	return ls.encryptWrite(raw) == nil
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
