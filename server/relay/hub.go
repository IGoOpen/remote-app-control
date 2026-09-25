// Package relay pairs apps shared with remote_app_control with the viewers
// watching them, and forwards messages between the two.
//
// The relay does not decode frames; it only reads the first byte of each
// message (its type) to decide how to route and prioritize it. Embed a Hub in
// any Go HTTP server:
//
//	hub := relay.NewHub(relay.Options{})
//	http.Handle("/ws/", hub)
package relay

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"log/slog"
	"math/big"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
)

// Message types that the relay needs to know about. See doc/protocol.md.
const (
	typeFrame         = 2
	frameFlagKeyframe = 1
	typeFirstInput    = 20
	typeLastInput     = 29
	typeControl       = 50
	closeBadCode      = 4404
	closeTooMany      = 4429
	closeDeviceLeft   = 4410
)

// Options configures a Hub. The zero value is usable.
type Options struct {
	// AuthorizeDevice decides whether an app may open a session. Return an
	// error to reject it. Nil allows every device.
	AuthorizeDevice func(r *http.Request) error

	// AuthorizeViewer decides whether a viewer may join the session with the
	// given code, e.g. by checking a support agent's login. Nil allows anyone
	// who knows the code.
	AuthorizeViewer func(r *http.Request, code string) error

	// CodeLength is the number of digits in a session code. Default 6.
	CodeLength int

	// MaxViewers per session. Default 4.
	MaxViewers int

	// FailedJoinsPerMinute limits code guessing per client IP. Default 10.
	FailedJoinsPerMinute int

	// OriginPatterns lists extra browser origins allowed to open viewer
	// connections, e.g. "support.example.com". Same-origin is always allowed.
	OriginPatterns []string

	Logger *slog.Logger
}

// Hub owns every live session. It is safe for concurrent use.
type Hub struct {
	opts     Options
	log      *slog.Logger
	mu       sync.Mutex
	sessions map[string]*session
	limiter  *joinLimiter
}

// SessionInfo is a snapshot of one session, for dashboards and admin APIs.
type SessionInfo struct {
	Code      string    `json:"code"`
	Viewers   int       `json:"viewers"`
	StartedAt time.Time `json:"startedAt"`
}

func NewHub(opts Options) *Hub {
	if opts.CodeLength <= 0 {
		opts.CodeLength = 6
	}
	if opts.MaxViewers <= 0 {
		opts.MaxViewers = 4
	}
	if opts.FailedJoinsPerMinute <= 0 {
		opts.FailedJoinsPerMinute = 10
	}
	logger := opts.Logger
	if logger == nil {
		logger = slog.Default()
	}
	return &Hub{
		opts:     opts,
		log:      logger,
		sessions: make(map[string]*session),
		limiter:  newJoinLimiter(opts.FailedJoinsPerMinute),
	}
}

// ServeHTTP routes /ws/device and /ws/viewer under any prefix.
func (h *Hub) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	switch {
	case strings.HasSuffix(r.URL.Path, "/ws/device"):
		h.ServeDevice(w, r)
	case strings.HasSuffix(r.URL.Path, "/ws/viewer"):
		h.ServeViewer(w, r)
	default:
		http.NotFound(w, r)
	}
}

// Sessions returns a snapshot of the live sessions.
func (h *Hub) Sessions() []SessionInfo {
	h.mu.Lock()
	defer h.mu.Unlock()
	out := make([]SessionInfo, 0, len(h.sessions))
	for _, s := range h.sessions {
		out = append(out, s.info())
	}
	return out
}

// acceptOptions enables compression with context takeover: consecutive
// frames are nearly identical, so deflate's shared window acts as a cheap
// delta encoding.
func (h *Hub) acceptOptions() *websocket.AcceptOptions {
	return &websocket.AcceptOptions{
		OriginPatterns:  h.opts.OriginPatterns,
		CompressionMode: websocket.CompressionContextTakeover,
	}
}

// ServeDevice accepts a connection from the app being shared.
func (h *Hub) ServeDevice(w http.ResponseWriter, r *http.Request) {
	if h.opts.AuthorizeDevice != nil {
		if err := h.opts.AuthorizeDevice(r); err != nil {
			http.Error(w, err.Error(), http.StatusUnauthorized)
			return
		}
	}
	conn, err := websocket.Accept(w, r, h.acceptOptions())
	if err != nil {
		return
	}
	conn.SetReadLimit(32 << 20)

	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()
	device := newPeer(ctx, conn)
	s := h.createSession(device)
	log := h.log.With("session", s.code)
	log.Info("device connected", "remote", r.RemoteAddr)

	device.sendControl(map[string]any{"event": "session", "code": s.code})

	err = device.readLoop(ctx, func(msg []byte) {
		for _, v := range s.viewerList() {
			if msg[0] == typeFrame {
				v.sendFrame(msg, s.requestKeyframe)
			} else {
				v.send(msg)
			}
		}
	})
	h.removeSession(s)
	for _, v := range s.viewerList() {
		v.sendControl(map[string]any{"event": "device_left"})
		v.close(closeDeviceLeft, "the app ended the session")
	}
	device.close(websocket.StatusNormalClosure, "")
	log.Info("device disconnected", "reason", closeReason(err))
}

// ServeViewer accepts a connection from someone watching a session.
func (h *Hub) ServeViewer(w http.ResponseWriter, r *http.Request) {
	ip := clientIP(r)
	code := r.URL.Query().Get("code")
	if h.opts.AuthorizeViewer != nil {
		if err := h.opts.AuthorizeViewer(r, code); err != nil {
			http.Error(w, err.Error(), http.StatusUnauthorized)
			return
		}
	}
	conn, err := websocket.Accept(w, r, h.acceptOptions())
	if err != nil {
		return
	}
	conn.SetReadLimit(1 << 20)

	// Rejections happen after the upgrade so browsers can read the reason.
	if !h.limiter.allow(ip) {
		conn.Close(closeTooMany, "too many attempts, try again later")
		return
	}
	s := h.lookup(code)
	if s == nil {
		h.limiter.fail(ip)
		conn.Close(closeBadCode, "no session with this code")
		return
	}

	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()
	viewer := newPeer(ctx, conn)
	count, ok := s.addViewer(viewer, h.opts.MaxViewers)
	if !ok {
		conn.Close(closeTooMany, "this session has too many viewers")
		return
	}
	log := h.log.With("session", s.code)
	log.Info("viewer joined", "remote", r.RemoteAddr, "viewers", count)
	s.device.sendControl(map[string]any{"event": "viewers", "count": count, "joined": true})

	err = viewer.readLoop(ctx, func(msg []byte) {
		// Viewers may only send input; everything else is dropped.
		if msg[0] >= typeFirstInput && msg[0] <= typeLastInput {
			s.device.send(msg)
		}
	})
	count = s.removeViewer(viewer)
	s.device.sendControl(map[string]any{"event": "viewers", "count": count, "joined": false})
	viewer.close(websocket.StatusNormalClosure, "")
	log.Info("viewer left", "viewers", count, "reason", closeReason(err))
}

func (h *Hub) createSession(device *peer) *session {
	h.mu.Lock()
	defer h.mu.Unlock()
	for {
		code := randomCode(h.opts.CodeLength)
		if _, taken := h.sessions[code]; taken {
			continue
		}
		s := &session{code: code, device: device, viewers: map[*peer]struct{}{}, startedAt: time.Now()}
		h.sessions[code] = s
		return s
	}
}

func (h *Hub) removeSession(s *session) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.sessions[s.code] == s {
		delete(h.sessions, s.code)
	}
}

func (h *Hub) lookup(code string) *session {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.sessions[code]
}

type session struct {
	code      string
	device    *peer
	startedAt time.Time

	mu                  sync.Mutex
	viewers             map[*peer]struct{}
	lastKeyframeRequest time.Time
}

// keyframeInterval limits how often a lagging viewer can ask the app for a
// keyframe; one keyframe serves every viewer that is waiting.
const keyframeInterval = 250 * time.Millisecond

func (s *session) requestKeyframe() {
	s.mu.Lock()
	now := time.Now()
	due := now.Sub(s.lastKeyframeRequest) >= keyframeInterval
	if due {
		s.lastKeyframeRequest = now
	}
	s.mu.Unlock()
	if due {
		s.device.sendControl(map[string]any{"event": "keyframe"})
	}
}

func (s *session) addViewer(p *peer, max int) (int, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(s.viewers) >= max {
		return len(s.viewers), false
	}
	s.viewers[p] = struct{}{}
	return len(s.viewers), true
}

func (s *session) removeViewer(p *peer) int {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.viewers, p)
	return len(s.viewers)
}

func (s *session) viewerList() []*peer {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]*peer, 0, len(s.viewers))
	for v := range s.viewers {
		out = append(out, v)
	}
	return out
}

func (s *session) info() SessionInfo {
	s.mu.Lock()
	defer s.mu.Unlock()
	return SessionInfo{Code: s.code, Viewers: len(s.viewers), StartedAt: s.startedAt}
}

func randomCode(length int) string {
	var b strings.Builder
	for range length {
		n, err := rand.Int(rand.Reader, big.NewInt(10))
		if err != nil {
			panic(err)
		}
		b.WriteByte(byte('0' + n.Int64()))
	}
	return b.String()
}

func controlMessage(payload any) []byte {
	body, _ := json.Marshal(payload)
	return append([]byte{typeControl}, body...)
}

func clientIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

func closeReason(err error) string {
	if err == nil {
		return ""
	}
	if status := websocket.CloseStatus(err); status != -1 {
		return status.String()
	}
	if errors.Is(err, context.Canceled) {
		return "closed"
	}
	return err.Error()
}
