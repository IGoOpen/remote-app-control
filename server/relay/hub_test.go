package relay

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
)

func dial(t *testing.T, ctx context.Context, url string) *websocket.Conn {
	t.Helper()
	conn, _, err := websocket.Dial(ctx, url, nil)
	if err != nil {
		t.Fatalf("dial %s: %v", url, err)
	}
	conn.SetReadLimit(1 << 20)
	return conn
}

func readControl(t *testing.T, ctx context.Context, conn *websocket.Conn) map[string]any {
	t.Helper()
	_, msg, err := conn.Read(ctx)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if msg[0] != typeControl {
		t.Fatalf("expected control message, got type %d", msg[0])
	}
	var out map[string]any
	if err := json.Unmarshal(msg[1:], &out); err != nil {
		t.Fatal(err)
	}
	return out
}

func TestRelayPairsDeviceAndViewer(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	server := httptest.NewServer(NewHub(Options{}))
	defer server.Close()
	base := "ws" + strings.TrimPrefix(server.URL, "http")

	device := dial(t, ctx, base+"/ws/device")
	session := readControl(t, ctx, device)
	code, _ := session["code"].(string)
	if session["event"] != "session" || len(code) != 6 {
		t.Fatalf("unexpected session message: %v", session)
	}

	viewer := dial(t, ctx, base+"/ws/viewer?code="+code)
	joined := readControl(t, ctx, device)
	if joined["event"] != "viewers" || joined["count"] != float64(1) {
		t.Fatalf("unexpected join message: %v", joined)
	}

	// Device output reaches the viewer untouched.
	frame := []byte{typeFrame, 1, 2, 3}
	if err := device.Write(ctx, websocket.MessageBinary, frame); err != nil {
		t.Fatal(err)
	}
	if _, got, err := viewer.Read(ctx); err != nil || string(got) != string(frame) {
		t.Fatalf("viewer got %v, %v", got, err)
	}

	// Viewer input reaches the device; anything else is dropped.
	_ = viewer.Write(ctx, websocket.MessageBinary, []byte{typeFrame, 9})
	input := []byte{typeFirstInput, 0, 1}
	_ = viewer.Write(ctx, websocket.MessageBinary, input)
	if _, got, err := device.Read(ctx); err != nil || string(got) != string(input) {
		t.Fatalf("device got %v, %v", got, err)
	}

	viewer.Close(websocket.StatusNormalClosure, "")
	left := readControl(t, ctx, device)
	if left["count"] != float64(0) {
		t.Fatalf("unexpected leave message: %v", left)
	}
}

func TestRelayRejectsUnknownCode(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	server := httptest.NewServer(NewHub(Options{}))
	defer server.Close()
	base := "ws" + strings.TrimPrefix(server.URL, "http")

	viewer := dial(t, ctx, base+"/ws/viewer?code=000000")
	_, _, err := viewer.Read(ctx)
	if websocket.CloseStatus(err) != closeBadCode {
		t.Fatalf("expected close %d, got %v", closeBadCode, err)
	}
}

func TestLimiterBlocksRepeatedFailures(t *testing.T) {
	l := newJoinLimiter(3)
	for range 3 {
		if !l.allow("1.2.3.4") {
			t.Fatal("blocked too early")
		}
		l.fail("1.2.3.4")
	}
	if l.allow("1.2.3.4") {
		t.Fatal("expected block after 3 failures")
	}
	if !l.allow("5.6.7.8") {
		t.Fatal("other clients must not be affected")
	}
}

func TestSlowViewerSkipsToKeyframe(t *testing.T) {
	p := &peer{out: make(chan []byte, 2), done: make(chan struct{})}
	requests := 0
	request := func() { requests++ }
	delta := []byte{typeFrame, 0, 1}
	key := []byte{typeFrame, frameFlagKeyframe, 2}

	p.sendFrame(delta, request)
	p.sendFrame(delta, request)
	p.sendFrame(delta, request) // Buffer full: dropped.
	if requests != 1 || !p.needKeyframe.Load() {
		t.Fatalf("expected a keyframe request after a drop, got %d", requests)
	}

	<-p.out
	<-p.out
	p.sendFrame(delta, request) // Useless without the dropped frame.
	if len(p.out) != 0 {
		t.Fatal("delta queued while waiting for a keyframe")
	}
	p.sendFrame(key, request)
	p.sendFrame(delta, request)
	if len(p.out) != 2 || p.needKeyframe.Load() {
		t.Fatalf("expected keyframe then delta, got %d queued", len(p.out))
	}
	if got := <-p.out; got[1]&frameFlagKeyframe == 0 {
		t.Fatal("keyframe must come first")
	}
}
