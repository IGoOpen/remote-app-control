package relay

import (
	"sync"
	"time"
)

// joinLimiter blocks clients that keep failing to join, which makes guessing
// session codes impractical.
type joinLimiter struct {
	limit int
	mu    sync.Mutex
	fails map[string][]time.Time
}

func newJoinLimiter(limit int) *joinLimiter {
	return &joinLimiter{limit: limit, fails: map[string][]time.Time{}}
}

func (l *joinLimiter) allow(ip string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	return len(l.recent(ip)) < l.limit
}

func (l *joinLimiter) fail(ip string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.fails[ip] = append(l.recent(ip), time.Now())
}

// recent drops failures older than a minute. Callers hold the lock.
func (l *joinLimiter) recent(ip string) []time.Time {
	cutoff := time.Now().Add(-time.Minute)
	kept := l.fails[ip][:0]
	for _, t := range l.fails[ip] {
		if t.After(cutoff) {
			kept = append(kept, t)
		}
	}
	if len(kept) == 0 {
		delete(l.fails, ip)
		return nil
	}
	l.fails[ip] = kept
	return kept
}
