package main

import (
	"encoding/json"
	"flag"
	"log"
	"net/http"
	"os"

	"github.com/shepaw/storage-node/internal/protocol"
	"github.com/shepaw/storage-node/internal/store"
)

func main() {
	root := flag.String("root", "./data", "store root directory")
	device := flag.String("device", "0000000000000001", "this node device_id (16 hex)")
	listen := flag.String("listen", ":8787", "HTTP listen address")
	flag.Parse()

	s, err := store.Open(*root, *device)
	if err != nil {
		log.Fatal(err)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/health", func(w http.ResponseWriter, _ *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]any{
			"ok": true, "device": *device, "protocol": protocol.ProtocolVersion,
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
			body.Caller = *device
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

	log.Printf("storage-node device=%s root=%s listen=%s", *device, *root, *listen)
	if err := http.ListenAndServe(*listen, mux); err != nil {
		log.Println(err)
		os.Exit(1)
	}
}
