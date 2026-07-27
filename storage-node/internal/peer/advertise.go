package peer

import (
	"fmt"
	"net"
	"strings"
)

// AdvertiseLocalWS builds ws://<lan-ip>:<port>/peer/ws from a listen addr
// like ":8787" or "0.0.0.0:8787".
func AdvertiseLocalWS(listen string) string {
	host, port, err := net.SplitHostPort(listen)
	if err != nil {
		return "ws://127.0.0.1:8787/peer/ws"
	}
	if host == "" || host == "0.0.0.0" || host == "::" {
		host = firstNonLoopbackIPv4()
		if host == "" {
			host = "127.0.0.1"
		}
	}
	if strings.Contains(host, ":") {
		host = "[" + host + "]"
	}
	return fmt.Sprintf("ws://%s:%s/peer/ws", host, port)
}

func firstNonLoopbackIPv4() string {
	ifaces, err := net.Interfaces()
	if err != nil {
		return ""
	}
	for _, iface := range ifaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		addrs, _ := iface.Addrs()
		for _, a := range addrs {
			var ip net.IP
			switch v := a.(type) {
			case *net.IPNet:
				ip = v.IP
			case *net.IPAddr:
				ip = v.IP
			}
			if ip == nil || ip.IsLoopback() {
				continue
			}
			ip = ip.To4()
			if ip != nil {
				return ip.String()
			}
		}
	}
	return ""
}
