package main

import (
	"bufio"
	"encoding/json"
	"net"
	"strings"
	"testing"
	"time"
)

// tc is a test client speaking the wire protocol.
type tc struct {
	t    *testing.T
	conn net.Conn
	sc   *bufio.Scanner
	last stateJ
}

func startServer(t *testing.T) string {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	h := NewHub()
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go h.serve(c)
		}
	}()
	return ln.Addr().String()
}

func dial(t *testing.T, addr, name string) *tc {
	t.Helper()
	conn, err := net.Dial("tcp", addr)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	c := &tc{t: t, conn: conn, sc: bufio.NewScanner(conn)}
	c.sc.Buffer(make([]byte, 4096), 1<<20)
	c.send(map[string]any{"t": "hello", "name": name})
	return c
}

func (c *tc) send(v map[string]any) {
	b, _ := json.Marshal(v)
	c.conn.Write(append(b, '\n'))
}

// waitFor reads messages until match returns true for one of them.
func (c *tc) waitFor(what string, match func(t string, raw []byte) bool) []byte {
	c.t.Helper()
	c.conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	for c.sc.Scan() {
		raw := append([]byte(nil), c.sc.Bytes()...)
		var head struct {
			T string `json:"t"`
		}
		json.Unmarshal(raw, &head)
		if head.T == "state" {
			json.Unmarshal(raw, &c.last)
		}
		if match(head.T, raw) {
			return raw
		}
	}
	c.t.Fatalf("never got %s: %v", what, c.sc.Err())
	return nil
}

func (c *tc) msg(kind string) map[string]any {
	c.t.Helper()
	var m map[string]any
	json.Unmarshal(c.waitFor(kind, func(t string, _ []byte) bool { return t == kind }), &m)
	return m
}

func (c *tc) state(what string, ok func(st stateJ) bool) stateJ {
	c.t.Helper()
	c.waitFor(what, func(t string, raw []byte) bool {
		if t != "state" {
			return false
		}
		var st stateJ
		json.Unmarshal(raw, &st)
		return ok(st)
	})
	return c.last
}

func (c *tc) errorMsg() string {
	c.t.Helper()
	return c.msg("error")["msg"].(string)
}

func TestRejoinAfterDrop(t *testing.T) {
	addr := startServer(t)
	a := dial(t, addr, "Ann")
	a.send(map[string]any{"t": "create", "bots": 2, "settings": map[string]any{"turnTime": 0}})
	seat := a.msg("seat")
	code, token := seat["code"].(string), seat["token"].(string)
	a.state("lobby", func(st stateJ) bool { return len(st.Players) == 3 })
	a.send(map[string]any{"t": "start"})
	before := a.state("playing", func(st stateJ) bool { return st.Phase == "playing" })
	a.conn.Close() // crash

	// Bots must not play on while nobody is connected.
	time.Sleep(200 * time.Millisecond)
	b := dial(t, addr, "Ann")
	b.send(map[string]any{"t": "rejoin", "code": code, "token": "wrong"})
	if m := b.msg("rejoin_failed"); m["msg"] == "" {
		t.Fatal("bad token should fail")
	}
	b.send(map[string]any{"t": "rejoin", "code": code, "token": token})
	if got := b.msg("seat")["id"]; got != before.You {
		t.Fatalf("rejoined as %v, want seat %s", got, before.You)
	}
	st := b.state("back in game", func(st stateJ) bool { return st.Phase == "playing" })
	if st.You != before.You || st.Host != before.You {
		t.Fatalf("after rejoin you=%s host=%s, want %s", st.You, st.Host, before.You)
	}
	for _, p := range st.Players {
		if p.ID == st.You && (p.Away || p.Bot) {
			t.Fatal("rejoined seat still marked away/bot")
		}
	}
	// It's a real seat again: the player can act.
	b.send(map[string]any{"t": "chat", "text": "back!"})
	b.waitFor("own chat", func(t string, raw []byte) bool { return t == "chat" && strings.Contains(string(raw), "back!") })
}

func TestHostToolsAndReady(t *testing.T) {
	addr := startServer(t)
	a := dial(t, addr, "Host")
	a.send(map[string]any{"t": "create", "settings": map[string]any{}})
	code := a.msg("seat")["code"].(string)
	b := dial(t, addr, "Guest")
	b.send(map[string]any{"t": "join", "code": code})
	b.msg("seat")
	a.state("guest joined", func(st stateJ) bool { return len(st.Players) == 2 })

	// Ready check: the host can't start until the guest is ready.
	a.send(map[string]any{"t": "start"})
	if e := a.errorMsg(); !strings.Contains(e, "Guest") {
		t.Fatalf("start before ready: %q", e)
	}
	b.send(map[string]any{"t": "ready", "ready": true})
	a.state("guest ready", func(st stateJ) bool { return len(st.Players) == 2 && st.Players[1].Ready })

	// Hand over host, then the new host kicks the old one.
	guestID := a.last.Players[1].ID
	a.send(map[string]any{"t": "make_host", "target": guestID})
	b.state("guest is host", func(st stateJ) bool { return st.Host == guestID })
	b.send(map[string]any{"t": "kick", "target": a.last.Players[0].ID})
	if a.msg("kicked")["msg"] == "" {
		t.Fatal("no kick message")
	}
	b.state("host gone", func(st stateJ) bool { return len(st.Players) == 1 })
	a.send(map[string]any{"t": "join", "code": code})
	if e := a.errorMsg(); !strings.Contains(e, "removed") {
		t.Fatalf("kicked player rejoining: %q", e)
	}
}

func TestChat(t *testing.T) {
	addr := startServer(t)
	a := dial(t, addr, "Ann")
	a.send(map[string]any{"t": "create", "settings": map[string]any{}})
	code := a.msg("seat")["code"].(string)
	a.send(map[string]any{"t": "chat", "text": "  gl\nhf   shithead  "})
	got := a.msg("chat")
	if got["sys"] == true { // "Ann joined" comes first
		got = a.msg("chat")
	}
	if got["text"] != "gl hf ********" || got["name"] != "Ann" {
		t.Fatalf("chat = %v", got)
	}
	// History is replayed to newcomers.
	b := dial(t, addr, "Ben")
	b.send(map[string]any{"t": "join", "code": code})
	hist := b.msg("chat_history")["items"].([]any)
	if len(hist) < 2 {
		t.Fatalf("history = %v", hist)
	}
	// Rate limit.
	for i := 0; i < chatBurst; i++ {
		b.send(map[string]any{"t": "chat", "text": "spam"})
	}
	b.send(map[string]any{"t": "chat", "text": "spam"})
	if e := b.errorMsg(); !strings.Contains(e, "too fast") {
		t.Fatalf("rate limit: %q", e)
	}
}

func TestQuickMatch(t *testing.T) {
	addr := startServer(t)
	a := dial(t, addr, "Ann")
	a.send(map[string]any{"t": "quick"})
	code := a.msg("seat")["code"].(string)
	st := a.state("quick lobby", func(st stateJ) bool { return st.Phase == "lobby" })
	if !st.Quick || st.StartsIn < 20 || st.Settings.MaxPlayers != quickSeats {
		t.Fatalf("quick lobby: quick=%v startsIn=%.0f max=%d", st.Quick, st.StartsIn, st.Settings.MaxPlayers)
	}
	b := dial(t, addr, "Ben")
	b.send(map[string]any{"t": "quick"})
	if got := b.msg("seat")["code"]; got != code {
		t.Fatalf("second player matched into %v, want %s", got, code)
	}
	// Quick Match rules are fixed; the host can start early and bots fill in.
	a.send(map[string]any{"t": "settings", "settings": map[string]any{"turnTime": 5}})
	if e := a.errorMsg(); !strings.Contains(e, "standard rules") {
		t.Fatalf("settings in quick room: %q", e)
	}
	a.send(map[string]any{"t": "start"})
	st = a.state("quick game", func(st stateJ) bool { return st.Phase == "playing" })
	if len(st.Players) != quickSeats {
		t.Fatalf("quick game has %d seats, want %d", len(st.Players), quickSeats)
	}
}

func TestCleanChat(t *testing.T) {
	for in, want := range map[string]string{
		"Classic Scunthorpe pass": "Classic Scunthorpe pass",
		"F U C K":                 "F U C K", // not worth chasing
		"what the fuck":           "what the ****",
		"sh1tty":                  "******",
		"‮evil\x00":               "evil",
		strings.Repeat("a", 300):  strings.Repeat("a", chatMaxRunes),
	} {
		if got := cleanChat(in); got != want {
			t.Errorf("cleanChat(%q) = %q, want %q", in, got, want)
		}
	}
}
