package peer

import (
	"encoding/base64"
	"encoding/json"
	"log"
	"net/http"
	"sync"
	"time"

	"github.com/gorilla/websocket"
	"github.com/shepaw/storage-node/internal/noise"
	"github.com/shepaw/storage-node/internal/protocol"
	"github.com/shepaw/storage-node/internal/store"
)

var upgrader = websocket.Upgrader{
	CheckOrigin: func(r *http.Request) bool { return true },
}

// Server handles /peer/ws Noise pairing + reconnect + encrypted store control frames.
type Server struct {
	Store           *store.Local
	Hub             *PairingHub
	Peers           *Store
	Sessions        *SessionRegistry
	Identity        *noise.Identity
	DeviceName      string
	LocalEndpoint   string // advertised ws://host:port/peer/ws
	ChannelEndpoint string // optional wss://channel.../peer/ws
}

func (s *Server) HandleWS(w http.ResponseWriter, r *http.Request) {
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("peer ws upgrade: %v", err)
		return
	}
	defer conn.Close()
	_ = conn.SetReadDeadline(time.Now().Add(60 * time.Second))

	_, raw, err := conn.ReadMessage()
	if err != nil {
		return
	}
	frame, err := noise.DecodeFrame(string(raw))
	if err != nil || frame.Type != noise.FrameHS {
		_ = conn.WriteMessage(websocket.TextMessage, []byte(`{"v":2,"t":"err","p":""}`))
		return
	}

	sess, err := noise.NewResponder(s.Identity)
	if err != nil {
		log.Printf("noise responder: %v", err)
		return
	}
	payload, peerPub, err := sess.ReadHandshake1(frame.Payload)
	if err != nil {
		log.Printf("hs1: %v", err)
		return
	}
	fp := FingerprintFromKey(peerPub)

	code := s.Hub.Code()
	if code != "" {
		if req, err := parsePairingRequest(payload); err == nil && req.PairingCode != "" {
			s.handlePairing(conn, sess, peerPub, fp, req, code)
			return
		}
	}

	// No active pairing (or payload is not a pairing request): treat as reconnect.
	s.handleReconnect(conn, sess, fp, payload)
}

func (s *Server) handlePairing(
	conn *websocket.Conn,
	sess *noise.Session,
	peerPub []byte,
	fp string,
	req PairingRequest,
	code string,
) {
	if !ConstantTimeEqual(req.PairingCode, code) {
		resp := PairingResponse{
			Accepted:     false,
			DeviceName:   s.DeviceName,
			DeviceID:     s.Identity.Fingerprint(),
			RejectReason: "Invalid pairing code",
		}
		b, _ := encodePairingResponse(resp)
		msg2, err := sess.WriteHandshake2(b)
		if err == nil {
			out, _ := noise.EncodeFrame(noise.Frame{Type: noise.FrameHS, Payload: msg2})
			_ = conn.WriteMessage(websocket.TextMessage, []byte(out))
		}
		return
	}

	sessionID := NewPeerID()
	wait := s.Hub.beginAcceptWait()
	s.Hub.setPending(&PendingRequest{
		DeviceName:  req.DeviceName,
		DeviceID:    req.DeviceID,
		Fingerprint: fp,
		SessionID:   sessionID,
	}, &activePairing{
		session:   sess,
		peerPub:   peerPub,
		request:   req,
		sessionID: sessionID,
	})

	var accept bool
	select {
	case accept = <-wait:
	case <-time.After(2 * time.Minute):
		accept = false
	}
	s.Hub.clearPairing()

	peerID := ""
	if accept {
		peerID = NewPeerID()
	}
	resp := PairingResponse{
		Accepted:        accept,
		DeviceName:      s.DeviceName,
		DeviceID:        s.Identity.Fingerprint(),
		PeerID:          peerID,
		LocalEndpoint:   s.LocalEndpoint,
		ChannelEndpoint: s.ChannelEndpoint,
	}
	if !accept {
		resp.RejectReason = "rejected"
		resp.LocalEndpoint = ""
		resp.ChannelEndpoint = ""
	}
	b, _ := encodePairingResponse(resp)
	msg2, err := sess.WriteHandshake2(b)
	if err != nil {
		log.Printf("hs2: %v", err)
		return
	}
	out, _ := noise.EncodeFrame(noise.Frame{Type: noise.FrameHS, Payload: msg2})
	if err := conn.WriteMessage(websocket.TextMessage, []byte(out)); err != nil {
		return
	}
	if !accept {
		return
	}

	_ = s.Peers.Upsert(Peer{
		Fingerprint:     fp,
		PublicKeyB64:    base64.StdEncoding.EncodeToString(peerPub),
		DeviceName:      req.DeviceName,
		PeerID:          peerID,
		TrustLevel:      protocol.TrustOwner,
		PairedAtMs:      NowMs(),
		LocalEndpoint:   req.LocalEndpoint,
		ChannelEndpoint: req.ChannelEndpoint,
	})
	log.Printf("paired peer fp=%s name=%s local=%s channel=%s",
		fp, req.DeviceName, req.LocalEndpoint, req.ChannelEndpoint)
	s.serveTransport(conn, sess, fp)
}

func (s *Server) handleReconnect(conn *websocket.Conn, sess *noise.Session, fp string, payload []byte) {
	known, err := s.Peers.Get(fp)
	if err != nil || known == nil {
		log.Printf("peer ws: reconnect rejected unknown fp=%s", fp)
		// Still complete Noise msg2 so initiator does not hang on decrypt;
		// payload marks rejection. Then close — no transport.
		ack, _ := json.Marshal(map[string]any{
			"type":      "reconnect_nack",
			"device_id": s.Identity.Fingerprint(),
			"reason":    "unknown_peer",
		})
		msg2, err := sess.WriteHandshake2(ack)
		if err == nil {
			out, _ := noise.EncodeFrame(noise.Frame{Type: noise.FrameHS, Payload: msg2})
			_ = conn.WriteMessage(websocket.TextMessage, []byte(out))
		}
		return
	}

	var req struct {
		Type            string `json:"type"`
		LocalEndpoint   string `json:"local_endpoint"`
		ChannelEndpoint string `json:"channel_endpoint"`
	}
	_ = json.Unmarshal(payload, &req)
	if req.LocalEndpoint != "" || req.ChannelEndpoint != "" {
		if err := s.Peers.MergeEndpoints(fp, req.LocalEndpoint, req.ChannelEndpoint); err != nil {
			log.Printf("reconnect merge endpoints: %v", err)
		} else {
			log.Printf("reconnect learned endpoints fp=%s local=%s channel=%s",
				fp, req.LocalEndpoint, req.ChannelEndpoint)
		}
	}

	ack := map[string]any{
		"type":      "reconnect_ack",
		"device_id": s.Identity.Fingerprint(),
	}
	if s.LocalEndpoint != "" {
		ack["local_endpoint"] = s.LocalEndpoint
	}
	if s.ChannelEndpoint != "" {
		ack["channel_endpoint"] = s.ChannelEndpoint
	}
	ackBytes, _ := json.Marshal(ack)
	msg2, err := sess.WriteHandshake2(ackBytes)
	if err != nil {
		log.Printf("reconnect hs2: %v", err)
		return
	}
	out, _ := noise.EncodeFrame(noise.Frame{Type: noise.FrameHS, Payload: msg2})
	if err := conn.WriteMessage(websocket.TextMessage, []byte(out)); err != nil {
		return
	}
	log.Printf("reconnected peer fp=%s name=%s", fp, known.DeviceName)
	s.serveTransport(conn, sess, fp)
}

func (s *Server) serveTransport(conn *websocket.Conn, sess *noise.Session, fp string) {
	_ = conn.SetReadDeadline(time.Time{})
	var writeMu sync.Mutex
	if s.Sessions != nil {
		s.Sessions.Add(fp, conn, sess, &writeMu)
		defer s.Sessions.Remove(fp, conn)
	}
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
			log.Printf("decrypt: %v", err)
			return
		}
		op, reqID, payload, ok := parseStoreControl(plain)
		if !ok {
			continue
		}
		// Notifications without req_id: apply/persist, no reply.
		if reqID == "" {
			switch op {
			case "master.pointer":
				_, _ = s.Store.Handle(protocol.Frame{Op: op, Payload: payload}, fp, protocol.TrustOwner, false)
				continue
			case "import.grant":
				if err := s.Store.ReceivePushedGrant(fp, payload); err != nil {
					log.Printf("import.grant push from %s: %v", fp, err)
				}
				continue
			}
		}
		data, err := s.Store.Handle(protocol.Frame{Op: op, Payload: payload}, fp, protocol.TrustOwner, false)
		if err == nil && op == "master.migrate" {
			s.overlayMigrateBroadcast(data)
		}
		var reply map[string]any
		if err != nil {
			code := "internal"
			msg := err.Error()
			if oe, ok := err.(*store.OpError); ok {
				code = oe.Code
				msg = oe.Msg
			}
			reply = map[string]any{
				"type": "store", "ns": "store", "op": "error", "v": 1,
				"code": code, "message": msg,
			}
		} else {
			reply = map[string]any{
				"type": "store", "ns": "store", "op": "result", "v": 1,
				"data": data,
			}
		}
		if reqID != "" {
			reply["req_id"] = reqID
		}
		rawReply, _ := json.Marshal(reply)
		ct, err := sess.Encrypt(rawReply)
		if err != nil {
			return
		}
		enc, _ := noise.EncodeFrame(noise.Frame{Type: noise.FrameData, Payload: ct})
		writeMu.Lock()
		_ = conn.WriteMessage(websocket.TextMessage, []byte(enc))
		writeMu.Unlock()
	}
}

// overlayMigrateBroadcast fans out master.pointer to live sessions and sets broadcast_peers.
func (s *Server) overlayMigrateBroadcast(data map[string]any) {
	if data == nil {
		return
	}
	master, _ := data["master"].(string)
	epoch := asInt64(data["epoch"])
	from := s.Identity.Fingerprint()
	n := 0
	if s.Sessions != nil {
		n = s.Sessions.FanoutMasterPointer(master, epoch, from)
	}
	data["broadcast_peers"] = n
}

func asInt64(v any) int64 {
	switch x := v.(type) {
	case int64:
		return x
	case int:
		return int64(x)
	case float64:
		return int64(x)
	case json.Number:
		i, _ := x.Int64()
		return i
	default:
		return 0
	}
}

// parseStoreControl accepts Dart flat StoreFrame JSON and nested {op,payload} (tests).
func parseStoreControl(plain []byte) (op, reqID string, payload map[string]any, ok bool) {
	var raw map[string]any
	if err := json.Unmarshal(plain, &raw); err != nil {
		return "", "", nil, false
	}
	op, _ = raw["op"].(string)
	if op == "" {
		return "", "", nil, false
	}
	reqID, _ = raw["req_id"].(string)
	if nested, isMap := raw["payload"].(map[string]any); isMap && raw["ns"] == nil {
		return op, reqID, nested, true
	}
	payload = make(map[string]any)
	for k, v := range raw {
		switch k {
		case "type", "ns", "op", "v", "req_id":
			continue
		default:
			payload[k] = v
		}
	}
	return op, reqID, payload, true
}
