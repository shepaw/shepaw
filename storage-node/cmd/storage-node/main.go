package main

import (
	"encoding/json"
	"flag"
	"log"
	"net/http"
	"os"
	"path/filepath"

	"github.com/shepaw/storage-node/internal/admin"
	"github.com/shepaw/storage-node/internal/noise"
	"github.com/shepaw/storage-node/internal/peer"
	"github.com/shepaw/storage-node/internal/protocol"
	"github.com/shepaw/storage-node/internal/store"
)

func main() {
	root := flag.String("root", "./data", "store root directory")
	deviceFlag := flag.String("device", "", "override device_id (default: Noise fingerprint)")
	listen := flag.String("listen", ":8787", "HTTP listen address")
	adminToken := flag.String("admin-token", os.Getenv("SHEPAW_ADMIN_TOKEN"),
		"admin UI/API token (env SHEPAW_ADMIN_TOKEN); empty = loopback-only")
	deviceName := flag.String("name", "storage-node", "device display name for pairing")
	flag.Parse()

	idPath := filepath.Join(*root, ".system", "noise_identity.json")
	identity, err := noise.LoadOrCreate(idPath)
	if err != nil {
		log.Fatal(err)
	}
	device := identity.Fingerprint()
	if *deviceFlag != "" {
		if *deviceFlag != device {
			log.Fatalf("-device %s does not match Noise fingerprint %s", *deviceFlag, device)
		}
	}

	s, err := store.Open(*root, device)
	if err != nil {
		log.Fatal(err)
	}
	peers := peer.NewStore(*root)
	hub := peer.NewPairingHub(identity, peers, *deviceName)
	peerSrv := &peer.Server{
		Store:      s,
		Hub:        hub,
		Peers:      peers,
		Identity:   identity,
		DeviceName: *deviceName,
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/health", func(w http.ResponseWriter, _ *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]any{
			"ok": true, "device": device, "protocol": protocol.ProtocolVersion,
			"noise": true, "fingerprint": device,
		})
	})
	mux.HandleFunc("/store", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "POST only", http.StatusMethodNotAllowed)
			return
		}
		var body struct {
			Op       string         `json:"op"`
			Payload  map[string]any `json:"payload"`
			Caller   string         `json:"caller"`
			Trust    string         `json:"trust"`
			Loopback bool           `json:"loopback"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			http.Error(w, err.Error(), 400)
			return
		}
		if body.Caller == "" {
			body.Caller = device
		}
		if body.Trust == "" {
			body.Trust = protocol.TrustOwner
		}
		if body.Payload == nil {
			body.Payload = map[string]any{}
		}
		data, err := s.Handle(protocol.Frame{Op: body.Op, Payload: body.Payload}, body.Caller, body.Trust, body.Loopback)
		if err != nil {
			code := "internal"
			msg := err.Error()
			if oe, ok := err.(*store.OpError); ok {
				code = oe.Code
				msg = oe.Msg
			}
			_ = json.NewEncoder(w).Encode(map[string]any{"op": "error", "code": code, "message": msg})
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"op": "result", "data": data})
	})
	mux.HandleFunc("/peer/ws", peerSrv.HandleWS)

	adminSrv := &admin.Server{
		Store:    s,
		Device:   device,
		Auth:     admin.AuthConfig{Token: *adminToken},
		Hub:      hub,
		Peers:    peers,
		Identity: identity,
		Listen:   *listen,
	}
	adminSrv.Mount(mux)

	if *adminToken == "" {
		log.Printf("admin: no token set — /admin only allows loopback")
	} else {
		log.Printf("admin: token required for /admin")
	}
	log.Printf("storage-node device=%s name=%s root=%s listen=%s (Noise IK /peer/ws)",
		device, *deviceName, *root, *listen)
	if err := http.ListenAndServe(*listen, mux); err != nil {
		log.Println(err)
		os.Exit(1)
	}
}
