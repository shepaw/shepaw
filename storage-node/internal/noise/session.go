package noise

import (
	"fmt"

	flynn "github.com/flynn/noise"
)

// Prologue matches Dart noisePrologueDefault / ACP v2.1 (peer pairing uses the same).
var Prologue = []byte("shepaw-acp/2.1")

func cipherSuite() flynn.CipherSuite {
	return flynn.NewCipherSuite(flynn.DH25519, flynn.CipherChaChaPoly, flynn.HashBLAKE2b)
}

// Session wraps a Noise_IK handshake and transport ciphers.
type Session struct {
	initiator bool
	hs        *flynn.HandshakeState
	sendCS    *flynn.CipherState
	recvCS    *flynn.CipherState
	peerPub   []byte
}

func NewInitiator(id *Identity, peerStatic []byte) (*Session, error) {
	if len(peerStatic) != 32 {
		return nil, fmt.Errorf("peer static must be 32 bytes")
	}
	hs, err := flynn.NewHandshakeState(flynn.Config{
		CipherSuite:   cipherSuite(),
		Pattern:       flynn.HandshakeIK,
		Initiator:     true,
		StaticKeypair: id.DHKey(),
		PeerStatic:    peerStatic,
		Prologue:      Prologue,
	})
	if err != nil {
		return nil, err
	}
	return &Session{initiator: true, hs: hs, peerPub: append([]byte(nil), peerStatic...)}, nil
}

func NewResponder(id *Identity) (*Session, error) {
	hs, err := flynn.NewHandshakeState(flynn.Config{
		CipherSuite:   cipherSuite(),
		Pattern:       flynn.HandshakeIK,
		Initiator:     false,
		StaticKeypair: id.DHKey(),
		Prologue:      Prologue,
	})
	if err != nil {
		return nil, err
	}
	return &Session{initiator: false, hs: hs}, nil
}

func (s *Session) WriteHandshake1(payload []byte) ([]byte, error) {
	if !s.initiator || s.hs == nil {
		return nil, fmt.Errorf("not initiator or wrong phase")
	}
	msg, _, _, err := s.hs.WriteMessage(nil, payload)
	return msg, err
}

func (s *Session) ReadHandshake1(msg []byte) (payload []byte, peerStatic []byte, err error) {
	if s.initiator || s.hs == nil {
		return nil, nil, fmt.Errorf("not responder or wrong phase")
	}
	payload, _, _, err = s.hs.ReadMessage(nil, msg)
	if err != nil {
		return nil, nil, err
	}
	s.peerPub = append([]byte(nil), s.hs.PeerStatic()...)
	return payload, s.peerPub, nil
}

func (s *Session) WriteHandshake2(payload []byte) ([]byte, error) {
	if s.initiator || s.hs == nil {
		return nil, fmt.Errorf("not responder or wrong phase")
	}
	msg, cs0, cs1, err := s.hs.WriteMessage(nil, payload)
	if err != nil {
		return nil, err
	}
	// Responder: cs0=recv, cs1=send (initiator's send is responder's recv)
	s.recvCS, s.sendCS = cs0, cs1
	s.hs = nil
	return msg, nil
}

func (s *Session) ReadHandshake2(msg []byte) (payload []byte, err error) {
	if !s.initiator || s.hs == nil {
		return nil, fmt.Errorf("not initiator or wrong phase")
	}
	payload, cs0, cs1, err := s.hs.ReadMessage(nil, msg)
	if err != nil {
		return nil, err
	}
	s.sendCS, s.recvCS = cs0, cs1
	s.hs = nil
	return payload, nil
}

func (s *Session) PeerStatic() []byte { return append([]byte(nil), s.peerPub...) }

func (s *Session) Encrypt(plaintext []byte) ([]byte, error) {
	if s.sendCS == nil {
		return nil, fmt.Errorf("session not ready")
	}
	return s.sendCS.Encrypt(nil, nil, plaintext)
}

func (s *Session) Decrypt(ciphertext []byte) ([]byte, error) {
	if s.recvCS == nil {
		return nil, fmt.Errorf("session not ready")
	}
	return s.recvCS.Decrypt(nil, nil, ciphertext)
}
