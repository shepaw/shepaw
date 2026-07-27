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
	Store      *store.Local
	Hub        *PairingHub
	Peers      *Store
	Identity   *noise.Identity
	DeviceName string
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
	s.handleReconnect(conn, sess, fp)
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
		Accepted:   accept,
		DeviceName: s.DeviceName,
		DeviceID:   s.Identity.Fingerprint(),
		PeerID:     peerID,
	}
	if !accept {
		resp.RejectReason = "rejected"
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
		Fingerprint:  fp,
		PublicKeyB64: base64.StdEncoding.EncodeToString(peerPub),
		DeviceName:   req.DeviceName,
		PeerID:       peerID,
		TrustLevel:   protocol.TrustOwner,
		PairedAtMs:   NowMs(),
	})
	log.Printf("paired peer fp=%s name=%s", fp, req.DeviceName)
	s.serveTransport(conn, sess, fp)
}

func (s *Server) handleReconnect(conn *websocket.Conn, sess *noise.Session, fp string) {
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

	ack, _ := json.Marshal(map[string]any{
		"type":      "reconnect_ack",
		"device_id": s.Identity.Fingerprint(),
	})
	msg2, err := sess.WriteHandshake2(ack)
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
		var body struct {
			Op      string         `json:"op"`
			Payload map[string]any `json:"payload"`
		}
		if err := json.Unmarshal(plain, &body); err != nil {
			continue
		}
		if body.Payload == nil {
			body.Payload = map[string]any{}
		}
		data, err := s.Store.Handle(protocol.Frame{Op: body.Op, Payload: body.Payload}, fp, protocol.TrustOwner, false)
		var reply map[string]any
		if err != nil {
			code := "internal"
			msg := err.Error()
			if oe, ok := err.(*store.OpError); ok {
				code = oe.Code
				msg = oe.Msg
			}
			reply = map[string]any{"op": "error", "code": code, "message": msg}
		} else {
			reply = map[string]any{"op": "result", "data": data}
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
