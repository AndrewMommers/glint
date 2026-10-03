package main

import (
	"bufio"
	"encoding/json"
	"net"
	"testing"
	"time"
)

// A human client plays a full round over TCP against three bots, always
// playing its first playable card.
func TestNetworkRound(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
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

	conn, err := net.Dial("tcp", ln.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	send := func(v any) {
		b, _ := json.Marshal(v)
		conn.Write(append(b, '\n'))
	}
	send(map[string]any{"t": "create", "name": "Tester", "bots": 3,
		"settings": map[string]any{"targetScore": 0, "turnTime": 0,
			"rules": map[string]any{"handSize": 5, "stacking": true, "jumpIn": true, "sevenO": true}}})

	sc := bufio.NewScanner(conn)
	sc.Buffer(make([]byte, 4096), 1<<20)
	conn.SetReadDeadline(time.Now().Add(240 * time.Second))
	started := false
	for sc.Scan() {
		var st stateJ
		json.Unmarshal(sc.Bytes(), &st)
		switch {
		case st.T == "error":
			t.Logf("server error: %s", sc.Text())
		case st.T != "state":
		case st.Phase == "lobby" && !started:
			if len(st.Players) != 4 {
				t.Fatalf("expected 4 seats, got %d", len(st.Players))
			}
			started = true
			send(map[string]any{"t": "start"})
		case st.Phase == "gameover":
			t.Logf("match %d round %d won by %s for %d points", st.Match, st.Round, st.Winner, st.RoundPoints)
			if st.Match != 1 {
				t.Fatalf("first match should be match 1, got %d", st.Match)
			}
			// "Play again": a new match restarts at round 1 but gets a new match number,
			// so clients can tell it apart from the one that just ended.
			send(map[string]any{"t": "start"})
			for sc.Scan() {
				var next stateJ
				json.Unmarshal(sc.Bytes(), &next)
				if next.T == "state" && next.Phase == "playing" {
					if next.Match != 2 || next.Round != 1 {
						t.Fatalf("play again: want match 2 round 1, got match %d round %d", next.Match, next.Round)
					}
					return
				}
			}
			t.Fatal("no state after play again")
		case st.Phase == "playing" && st.Turn == st.You:
			if st.CanUno {
				send(map[string]any{"t": "uno"})
			}
			if len(st.Playable) > 0 {
				send(map[string]any{"t": "play", "card": st.Playable[0], "color": "red"})
			} else if st.Drawn >= 0 {
				send(map[string]any{"t": "pass"})
			} else {
				send(map[string]any{"t": "draw"})
			}
		}
	}
	t.Fatalf("connection ended before the round finished: %v", sc.Err())
}
