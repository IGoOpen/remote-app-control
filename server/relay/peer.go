package relay

import (
	"context"
	"sync"
	"sync/atomic"
	"time"

	"github.com/coder/websocket"
)

const (
	sendBuffer   = 64
	writeTimeout = 10 * time.Second
)

// peer is one WebSocket connection with its own writer goroutine, so a slow
// client never blocks the sender.
type peer struct {
	conn     *websocket.Conn
	out      chan []byte
	done     chan struct{}
	stopOnce sync.Once

	// Set after a frame had to be dropped: frames are deltas, so everything
	// until the next keyframe is useless to this client.
	needKeyframe atomic.Bool
}

func newPeer(ctx context.Context, conn *websocket.Conn) *peer {
	p := &peer{conn: conn, out: make(chan []byte, sendBuffer), done: make(chan struct{})}
	go p.writeLoop(ctx)
	return p
}

// send queues msg. A client too slow to take it is stuck, so it is
// disconnected. Frames go through sendFrame instead.
func (p *peer) send(msg []byte) {
	select {
	case <-p.done:
		return
	default:
	}
	select {
	case p.out <- msg:
	default:
		p.close(websocket.StatusPolicyViolation, "client too slow")
	}
}

// sendFrame queues a frame, dropping it if the client is behind. Frames
// only carry what changed, so after a drop the client skips every frame
// until a keyframe fits, and requestKeyframe asks the app for one.
func (p *peer) sendFrame(msg []byte, requestKeyframe func()) {
	select {
	case <-p.done:
		return
	default:
	}
	keyframe := len(msg) > 1 && msg[1]&frameFlagKeyframe != 0
	if !keyframe && p.needKeyframe.Load() {
		// Keep asking: the request is rate limited per session, and an
		// earlier keyframe may have been dropped too.
		requestKeyframe()
		return
	}
	select {
	case p.out <- msg:
		if keyframe {
			p.needKeyframe.Store(false)
		}
	default:
		p.needKeyframe.Store(true)
		requestKeyframe()
	}
}

func (p *peer) sendControl(payload any) {
	p.send(controlMessage(payload))
}

func (p *peer) writeLoop(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			return
		case <-p.done:
			return
		case msg := <-p.out:
			wctx, cancel := context.WithTimeout(ctx, writeTimeout)
			err := p.conn.Write(wctx, websocket.MessageBinary, msg)
			cancel()
			if err != nil {
				p.close(websocket.StatusGoingAway, "write failed")
				return
			}
		}
	}
}

// readLoop calls handle for every non-empty binary message until the
// connection closes.
func (p *peer) readLoop(ctx context.Context, handle func([]byte)) error {
	for {
		typ, msg, err := p.conn.Read(ctx)
		if err != nil {
			return err
		}
		if typ == websocket.MessageBinary && len(msg) > 0 {
			handle(msg)
		}
	}
}

func (p *peer) close(code websocket.StatusCode, reason string) {
	p.stopOnce.Do(func() {
		close(p.done)
		// Flush what is already queued, e.g. a final control message.
		go func() {
			for {
				select {
				case msg := <-p.out:
					ctx, cancel := context.WithTimeout(context.Background(), time.Second)
					_ = p.conn.Write(ctx, websocket.MessageBinary, msg)
					cancel()
				default:
					_ = p.conn.Close(code, reason)
					return
				}
			}
		}()
	})
}
