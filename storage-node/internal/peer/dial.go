package peer

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
	"github.com/shepaw/storage-node/internal/noise"
)

const dialTimeout = 12 * time.Second

// Dialer actively reconnects to paired peers (outbound Noise IK) so migrate
// seed can CallStore when the old master is not inbound-connected.
type Dialer struct {
	Identity        *noise.Identity
	Peers           *Store
	Sessions        *SessionRegistry
	LocalEndpoint   string
	ChannelEndpoint string

	mu     sync.Mutex
	dialed map[string]*websocket.Conn // fp → outbound conn (short-lived)
}

func NewDialer(
	identity *noise.Identity,
	peers *Store,
	sessions *SessionRegistry,
	localEndpoint, channelEndpoint string,
) *Dialer {
	return &Dialer{
		Identity:        identity,
		Peers:           peers,
		Sessions:        sessions,
		LocalEndpoint:   localEndpoint,
		ChannelEndpoint: channelEndpoint,
		dialed:          map[string]*websocket.Conn{},
	}
}

// Ensure connects to deviceID if not already in Sessions.
// Tries LocalEndpoint then ChannelEndpoint from paired_peers.
func (d *Dialer) Ensure(deviceID string) error {
	if d == nil || d.Sessions == nil || d.Peers == nil || d.Identity == nil {
		return fmt.Errorf("dialer not configured")
	}
	if d.Sessions.Has(deviceID) {
		return nil
	}
	p, err := d.Peers.Get(deviceID)
	if err != nil {
		return err
	}
	if p == nil {
		return fmt.Errorf("peer not paired: %s", deviceID)
	}
	endpoints := make([]string, 0, 2)
	if strings.TrimSpace(p.LocalEndpoint) != "" {
		endpoints = append(endpoints, strings.TrimSpace(p.LocalEndpoint))
	}
	if strings.TrimSpace(p.ChannelEndpoint) != "" {
		endpoints = append(endpoints, strings.TrimSpace(p.ChannelEndpoint))
	}
	if len(endpoints) == 0 {
		return fmt.Errorf("no endpoints for %s", deviceID)
	}
	var lastErr error
	for _, ep := range endpoints {
		if err := d.dialOne(deviceID, p, ep); err != nil {
			log.Printf("dial %s via %s: %v", deviceID, ep, err)
			lastErr = err
			continue
		}
		return nil
	}
	if lastErr == nil {
		lastErr = fmt.Errorf("dial failed")
	}
	return lastErr
}

// Release closes a short-lived outbound dial for deviceID (no-op if inbound-only).
func (d *Dialer) Release(deviceID string) {
	if d == nil {
		return
	}
	d.mu.Lock()
	conn := d.dialed[deviceID]
	delete(d.dialed, deviceID)
	d.mu.Unlock()
	if conn != nil {
		_ = conn.Close()
	}
}

func (d *Dialer) dialOne(deviceID string, p *Peer, endpoint string) error {
	pub, err := base64.StdEncoding.DecodeString(p.PublicKeyB64)
	if err != nil || len(pub) != 32 {
		return fmt.Errorf("bad peer public key")
	}
	dialer := websocket.Dialer{HandshakeTimeout: dialTimeout}
	conn, _, err := dialer.Dial(endpoint, http.Header{})
	if err != nil {
		return err
	}
	_ = conn.SetReadDeadline(time.Now().Add(dialTimeout))
	_ = conn.SetWriteDeadline(time.Now().Add(dialTimeout))

	initSess, err := noise.NewInitiator(d.Identity, pub)
	if err != nil {
		_ = conn.Close()
		return err
	}
	msg1Body := map[string]any{
		"type":      "reconnect",
		"device_id": d.Identity.Fingerprint(),
	}
	if d.LocalEndpoint != "" {
		msg1Body["local_endpoint"] = d.LocalEndpoint
	}
	if d.ChannelEndpoint != "" {
		msg1Body["channel_endpoint"] = d.ChannelEndpoint
	}
	payload, _ := json.Marshal(msg1Body)
	msg1, err := initSess.WriteHandshake1(payload)
	if err != nil {
		_ = conn.Close()
		return err
	}
	frame1, err := noise.EncodeFrame(noise.Frame{Type: noise.FrameHS, Payload: msg1})
	if err != nil {
		_ = conn.Close()
		return err
	}
	if err := conn.WriteMessage(websocket.TextMessage, []byte(frame1)); err != nil {
		_ = conn.Close()
		return err
	}

	_, raw2, err := conn.ReadMessage()
	if err != nil {
		_ = conn.Close()
		return err
	}
	fr2, err := noise.DecodeFrame(string(raw2))
	if err != nil || fr2.Type != noise.FrameHS {
		_ = conn.Close()
		return fmt.Errorf("expected hs frame")
	}
	ackPayload, err := initSess.ReadHandshake2(fr2.Payload)
	if err != nil {
		_ = conn.Close()
		return err
	}
	var ack map[string]any
	_ = json.Unmarshal(ackPayload, &ack)
	if ack["type"] == "reconnect_nack" {
		_ = conn.Close()
		return fmt.Errorf("reconnect_nack: %v", ack["reason"])
	}
	if ack["type"] != "reconnect_ack" {
		_ = conn.Close()
		return fmt.Errorf("unexpected ack type %v", ack["type"])
	}

	_ = conn.SetReadDeadline(time.Time{})
	_ = conn.SetWriteDeadline(time.Time{})
	var writeMu sync.Mutex
	d.Sessions.Add(deviceID, conn, initSess, &writeMu)
	d.mu.Lock()
	if old := d.dialed[deviceID]; old != nil && old != conn {
		_ = old.Close()
	}
	d.dialed[deviceID] = conn
	d.mu.Unlock()

	go d.serveOutbound(conn, initSess, deviceID, &writeMu)
	log.Printf("dialed peer fp=%s via %s", deviceID, endpoint)
	return nil
}

// serveOutbound only completes CallStore replies (outbound dial is for RPC seed).
func (d *Dialer) serveOutbound(conn *websocket.Conn, sess *noise.Session, fp string, writeMu *sync.Mutex) {
	defer func() {
		d.Sessions.Remove(fp, conn)
		d.mu.Lock()
		if d.dialed[fp] == conn {
			delete(d.dialed, fp)
		}
		d.mu.Unlock()
		_ = conn.Close()
	}()
	for {
		_ = conn.SetReadDeadline(time.Now().Add(30 * time.Minute))
		_, msg, err := conn.ReadMessage()
		if err != nil {
			return
		}
		fr, err := noise.DecodeFrame(string(msg))
		if err != nil || fr.Type != noise.FrameData {
			continue
		}
		plain, err := sess.Decrypt(fr.Payload)
		if err != nil {
			log.Printf("outbound decrypt %s: %v", fp, err)
			return
		}
		var raw map[string]any
		if err := json.Unmarshal(plain, &raw); err != nil {
			continue
		}
		op, _ := raw["op"].(string)
		reqID, _ := raw["req_id"].(string)
		if (op == "result" || op == "error") && reqID != "" {
			_ = d.Sessions.DeliverReply(fp, reqID, raw)
		}
	}
}
