package main

import (
	"fmt"
	"math/rand"
	"sort"
	"sync"
	"sync/atomic"
	"time"
)

// Hub tracks all rooms on the server.
type Hub struct {
	mu        sync.Mutex
	rooms     map[string]*Room
	info      map[string]roomInfo // public lobbies, maintained by the rooms themselves
	rng       *rand.Rand
	nextID    atomic.Int64
	clients   atomic.Int64
	lastAct   atomic.Int64 // unix seconds of the last disconnect / connect
	accounts  *Accounts    // nil when accounts are disabled
	invites   *Invites     // non-nil when registration needs an invite code
	minClient string       // oldest client version allowed ("" = any)
	feedback  *Feedback    // nil when feedback collection is off
	appwrite  *Appwrite    // non-nil when Appwrite is the backend
	perIP     map[string]int
	ipMu      sync.Mutex
}

const maxConnsPerIP = 12

// admit counts a connection from ip; false means the limit is reached.
func (h *Hub) admit(ip string) bool {
	h.ipMu.Lock()
	defer h.ipMu.Unlock()
	if h.perIP == nil {
		h.perIP = map[string]int{}
	}
	if h.perIP[ip] >= maxConnsPerIP {
		return false
	}
	h.perIP[ip]++
	return true
}

func (h *Hub) release(ip string) {
	h.ipMu.Lock()
	defer h.ipMu.Unlock()
	if h.perIP[ip]--; h.perIP[ip] <= 0 {
		delete(h.perIP, ip)
	}
}

func NewHub() *Hub {
	h := &Hub{
		rooms: map[string]*Room{},
		info:  map[string]roomInfo{},
		rng:   rand.New(rand.NewSource(time.Now().UnixNano())),
	}
	h.lastAct.Store(time.Now().Unix())
	return h
}

func (h *Hub) newID(prefix string) string {
	return fmt.Sprintf("%s%d", prefix, h.nextID.Add(1))
}

const codeLetters = "ABCDEFGHJKLMNPQRSTUVWXYZ" // no I/O to avoid confusion

func (h *Hub) createRoom() *Room {
	h.mu.Lock()
	defer h.mu.Unlock()
	for {
		b := make([]byte, 4)
		for i := range b {
			b[i] = codeLetters[h.rng.Intn(len(codeLetters))]
		}
		code := string(b)
		if _, taken := h.rooms[code]; !taken {
			r := newRoom(code, h, h.rng.Int63())
			h.rooms[code] = r
			return r
		}
	}
}

func (h *Hub) get(code string) *Room {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.rooms[code]
}

func (h *Hub) remove(code string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	delete(h.rooms, code)
	delete(h.info, code)
}

func (h *Hub) setInfo(code string, info *roomInfo) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if _, ok := h.rooms[code]; !ok {
		return
	}
	if info == nil {
		delete(h.info, code)
	} else {
		h.info[code] = *info
	}
}

// quickRooms lists Quick Match lobbies with a free seat, fullest first.
func (h *Hub) quickRooms() []*Room {
	h.mu.Lock()
	defer h.mu.Unlock()
	var infos []roomInfo
	for _, i := range h.info {
		if i.Quick && i.Players < i.Max {
			infos = append(infos, i)
		}
	}
	sort.Slice(infos, func(a, b int) bool { return infos[a].Players > infos[b].Players })
	var out []*Room
	for _, i := range infos {
		if r := h.rooms[i.Code]; r != nil {
			out = append(out, r)
		}
	}
	return out
}

func (h *Hub) publicRooms() []roomInfo {
	h.mu.Lock()
	defer h.mu.Unlock()
	out := []roomInfo{}
	for _, i := range h.info {
		out = append(out, i)
	}
	sort.Slice(out, func(a, b int) bool { return out[a].Code < out[b].Code })
	return out
}
