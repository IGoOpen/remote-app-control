// Command remote-relay runs a standalone relay server and, optionally, serves
// the web viewer.
package main

import (
	"crypto/subtle"
	"encoding/json"
	"errors"
	"flag"
	"log/slog"
	"net/http"
	"os"
	"strings"

	"github.com/IGoOpen/remote-app-control/server/relay"
)

func main() {
	addr := flag.String("addr", ":8080", "listen address")
	web := flag.String("web", "", "directory of the built web viewer to serve at /")
	deviceToken := flag.String("device-token", os.Getenv("RELAY_DEVICE_TOKEN"),
		"if set, apps must pass this token to open a session")
	adminToken := flag.String("admin-token", os.Getenv("RELAY_ADMIN_TOKEN"),
		"if set, enables GET /api/sessions with this bearer token")
	allowOrigins := flag.String("allow-origin", os.Getenv("RELAY_ALLOW_ORIGIN"),
		"comma-separated browser origins, besides this server's own, allowed to connect viewers (e.g. support.example.com,localhost:5173)")
	flag.Parse()

	opts := relay.Options{}
	for _, origin := range strings.Split(*allowOrigins, ",") {
		if origin = strings.TrimSpace(origin); origin != "" {
			opts.OriginPatterns = append(opts.OriginPatterns, origin)
		}
	}
	if *deviceToken != "" {
		opts.AuthorizeDevice = func(r *http.Request) error {
			if !tokenEqual(r.URL.Query().Get("token"), *deviceToken) {
				return errors.New("invalid device token")
			}
			return nil
		}
	}
	hub := relay.NewHub(opts)

	mux := http.NewServeMux()
	mux.Handle("/ws/", hub)
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.Write([]byte("ok"))
	})
	if *adminToken != "" {
		mux.HandleFunc("GET /api/sessions", func(w http.ResponseWriter, r *http.Request) {
			if !tokenEqual(r.Header.Get("Authorization"), "Bearer "+*adminToken) {
				http.Error(w, "unauthorized", http.StatusUnauthorized)
				return
			}
			w.Header().Set("Content-Type", "application/json")
			json.NewEncoder(w).Encode(hub.Sessions())
		})
	}
	if *web != "" {
		mux.Handle("/", http.FileServer(http.Dir(*web)))
	}

	slog.Info("relay listening", "addr", *addr, "web", *web, "deviceAuth", *deviceToken != "")
	if err := http.ListenAndServe(*addr, mux); err != nil {
		slog.Error("server stopped", "err", err)
		os.Exit(1)
	}
}

func tokenEqual(got, want string) bool {
	return subtle.ConstantTimeCompare([]byte(got), []byte(want)) == 1
}
