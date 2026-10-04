package main

import (
	"bufio"
	"crypto/rand"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"io"
	"net"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// A browser-style WebSocket client creates a room and sees its state.
func TestWebSocketClient(t *testing.T) {
	h := NewHub()
	srv := httptest.NewServer(httpHandler(h))
	defer srv.Close()
	conn, err := net.Dial("tcp", strings.TrimPrefix(srv.URL, "http://"))
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	key := make([]byte, 16)
	rand.Read(key)
	conn.Write([]byte("GET /ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: keep-alive, Upgrade\r\n" +
		"Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: " + base64.StdEncoding.EncodeToString(key) + "\r\n" +
		"X-Forwarded-For: 203.0.113.9\r\n\r\n"))
	br := bufio.NewReader(conn)
	status, _ := br.ReadString('\n')
	if !strings.Contains(status, "101") {
		t.Fatalf("handshake: %q", status)
	}
	for line, _ := br.ReadString('\n'); line != "\r\n"; line, _ = br.ReadString('\n') {
	}
	send := func(v any) { // masked text frame, as browsers send
		b, _ := json.Marshal(v)
		mask := []byte{1, 2, 3, 4}
		f := []byte{0x81, 0x80 | byte(len(b))}
		f = append(f, mask...)
		for i, c := range b {
			f = append(f, c^mask[i%4])
		}
		conn.Write(f)
	}
	pongs := 0
	var recv func() map[string]any
	recv = func() map[string]any {
		conn.SetReadDeadline(time.Now().Add(5 * time.Second))
		var head [2]byte
		if _, err := io.ReadFull(br, head[:]); err != nil {
			t.Fatal(err)
		}
		n := int(head[1] & 0x7F)
		if n == 126 {
			var b [2]byte
			io.ReadFull(br, b[:])
			n = int(binary.BigEndian.Uint16(b[:]))
		}
		p := make([]byte, n)
		io.ReadFull(br, p)
		if head[0]&0x0F == 0xA { // our ping's pong
			pongs++
			return recv()
		}
		var m map[string]any
		if err := json.Unmarshal(p, &m); err != nil {
			t.Fatalf("not one JSON message per frame: %q", p)
		}
		return m
	}
	if m := recv(); m["t"] != "welcome" {
		t.Fatalf("first message %v", m)
	}
	// Pings are answered with pongs.
	conn.Write([]byte{0x89, 0x80, 0, 0, 0, 0})
	send(map[string]any{"t": "create", "bots": 1, "settings": map[string]any{"public": false}})
	for {
		m := recv()
		if m["t"] == "state" {
			if len(m["players"].([]any)) != 2 {
				t.Fatalf("state: %v", m)
			}
			if pongs != 1 {
				t.Fatalf("got %d pongs, want 1", pongs)
			}
			return
		}
	}
}
