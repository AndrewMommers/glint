package main

// WebSocket support for the browser version of the game. Browsers can't open
// raw TCP connections, so the web build connects with WebSockets instead.
// Each text message is one protocol line, and wsConn turns the connection
// back into the newline-delimited stream that Hub.serve already speaks.
//
// This is a small RFC 6455 server (no extensions, no compression) so the
// server stays free of third-party dependencies. TLS is done in front of it
// by a reverse proxy (Caddy) with a publicly trusted certificate.

import (
	"bufio"
	"bytes"
	"crypto/sha1"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"io"
	"log"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"
)

const (
	wsGUID       = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
	wsMaxMessage = 64 * 1024
	opCont       = 0x0
	opText       = 0x1
	opBinary     = 0x2
	opClose      = 0x8
	opPing       = 0x9
	opPong       = 0xA

	// Browsers freeze a game running in a hidden tab, so it can't send its own
	// keepalive pings. The browser itself still answers WebSocket pings, so
	// the server pings and only drops a connection that's silent for wsIdle.
	wsPingEvery = 15 * time.Second
	wsIdle      = 60 * time.Second
)

// listenWS serves WebSocket game connections at /ws on addr (plain HTTP;
// the proxy in front adds TLS).
func (h *Hub) listenWS(addr string) {
	srv := &http.Server{Addr: addr, Handler: httpHandler(h), ReadHeaderTimeout: 10 * time.Second}
	log.Printf("WebSocket clients on ws://%s/ws", addr)
	if err := srv.ListenAndServe(); err != nil {
		log.Fatalf("websocket listener: %v", err)
	}
}

func httpHandler(h *Hub) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/ws", h.serveWS)
	return mux
}

func (h *Hub) serveWS(w http.ResponseWriter, r *http.Request) {
	if !strings.EqualFold(r.Header.Get("Upgrade"), "websocket") ||
		!headerHasToken(r.Header.Get("Connection"), "upgrade") ||
		r.Header.Get("Sec-WebSocket-Version") != "13" || r.Header.Get("Sec-WebSocket-Key") == "" {
		http.Error(w, "this endpoint only speaks WebSocket", http.StatusBadRequest)
		return
	}
	hj, ok := w.(http.Hijacker)
	if !ok {
		http.Error(w, "can't upgrade", http.StatusInternalServerError)
		return
	}
	conn, brw, err := hj.Hijack()
	if err != nil {
		return
	}
	sum := sha1.Sum([]byte(r.Header.Get("Sec-WebSocket-Key") + wsGUID))
	conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
	_, err = conn.Write([]byte("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" +
		"Sec-WebSocket-Accept: " + base64.StdEncoding.EncodeToString(sum[:]) + "\r\n\r\n"))
	conn.SetWriteDeadline(time.Time{})
	if err != nil {
		conn.Close()
		return
	}
	c := &wsConn{Conn: conn, br: brw.Reader, remote: forwardedAddr(r, conn.RemoteAddr()), done: make(chan struct{})}
	go c.pinger()
	h.serve(c)
	close(c.done)
}

func headerHasToken(v, token string) bool {
	for _, t := range strings.Split(v, ",") {
		if strings.EqualFold(strings.TrimSpace(t), token) {
			return true
		}
	}
	return false
}

// forwardedAddr is the player's real address when the request came through
// the proxy on this machine (so per-IP limits and kick bans work).
func forwardedAddr(r *http.Request, remote net.Addr) net.Addr {
	tcp, ok := remote.(*net.TCPAddr)
	if !ok || !tcp.IP.IsLoopback() {
		return remote
	}
	xff := r.Header.Get("X-Forwarded-For")
	if xff == "" {
		return remote
	}
	parts := strings.Split(xff, ",")
	if ip := net.ParseIP(strings.TrimSpace(parts[len(parts)-1])); ip != nil {
		return &net.TCPAddr{IP: ip}
	}
	return remote
}

// wsConn presents a WebSocket as a newline-delimited stream.
type wsConn struct {
	net.Conn
	br      *bufio.Reader
	remote  net.Addr
	pending []byte // unread rest of the current message, newline included
	wmu     sync.Mutex
	closed  bool
	done    chan struct{}
}

// SetReadDeadline is managed here (any frame, pongs included, keeps the
// connection alive), so the hub's ping-based deadline is ignored.
func (c *wsConn) SetReadDeadline(time.Time) error { return nil }

func (c *wsConn) pinger() {
	t := time.NewTicker(wsPingEvery)
	defer t.Stop()
	for {
		select {
		case <-t.C:
			if c.writeFrame(opPing, nil) != nil {
				return
			}
		case <-c.done:
			return
		}
	}
}

func (c *wsConn) RemoteAddr() net.Addr { return c.remote }

func (c *wsConn) Read(p []byte) (int, error) {
	for len(c.pending) == 0 {
		msg, err := c.readMessage()
		if err != nil {
			return 0, err
		}
		c.pending = append(msg, '\n')
	}
	n := copy(p, c.pending)
	c.pending = c.pending[n:]
	return n, nil
}

// Write sends one protocol line (Hub.serve writes exactly one per call).
func (c *wsConn) Write(p []byte) (int, error) {
	if err := c.writeFrame(opText, bytes.TrimSuffix(p, []byte{'\n'})); err != nil {
		return 0, err
	}
	return len(p), nil
}

func (c *wsConn) Close() error {
	c.wmu.Lock()
	if !c.closed {
		c.closed = true
		c.Conn.SetWriteDeadline(time.Now().Add(time.Second))
		c.Conn.Write([]byte{0x80 | opClose, 2, 0x03, 0xE8}) // 1000: normal closure
	}
	c.wmu.Unlock()
	return c.Conn.Close()
}

// readMessage returns the next data message, answering pings on the way.
func (c *wsConn) readMessage() ([]byte, error) {
	var msg []byte
	for {
		fin, op, payload, err := c.readFrame()
		if err != nil {
			return nil, err
		}
		switch op {
		case opClose:
			return nil, io.EOF
		case opPing:
			if err := c.writeFrame(opPong, payload); err != nil {
				return nil, err
			}
		case opPong:
		case opText, opBinary, opCont:
			msg = append(msg, payload...)
			if len(msg) > wsMaxMessage {
				return nil, errors.New("websocket: message too large")
			}
			if fin {
				if msg == nil {
					msg = []byte{}
				}
				return msg, nil
			}
		default:
			return nil, errors.New("websocket: bad opcode")
		}
	}
}

func (c *wsConn) readFrame() (fin bool, op byte, payload []byte, err error) {
	c.Conn.SetReadDeadline(time.Now().Add(wsIdle))
	var head [2]byte
	if _, err = io.ReadFull(c.br, head[:]); err != nil {
		return
	}
	fin, op = head[0]&0x80 != 0, head[0]&0x0F
	if head[1]&0x80 == 0 {
		return false, 0, nil, errors.New("websocket: client frames must be masked")
	}
	n := uint64(head[1] & 0x7F)
	switch n {
	case 126:
		var b [2]byte
		if _, err = io.ReadFull(c.br, b[:]); err != nil {
			return
		}
		n = uint64(binary.BigEndian.Uint16(b[:]))
	case 127:
		var b [8]byte
		if _, err = io.ReadFull(c.br, b[:]); err != nil {
			return
		}
		n = binary.BigEndian.Uint64(b[:])
	}
	if n > wsMaxMessage {
		return false, 0, nil, errors.New("websocket: frame too large")
	}
	var mask [4]byte
	if _, err = io.ReadFull(c.br, mask[:]); err != nil {
		return
	}
	payload = make([]byte, n)
	if _, err = io.ReadFull(c.br, payload); err != nil {
		return
	}
	for i := range payload {
		payload[i] ^= mask[i%4]
	}
	return
}

func (c *wsConn) writeFrame(op byte, payload []byte) error {
	c.wmu.Lock()
	defer c.wmu.Unlock()
	if c.closed {
		return net.ErrClosed
	}
	frame := make([]byte, 0, len(payload)+10)
	frame = append(frame, 0x80|op)
	switch n := len(payload); {
	case n < 126:
		frame = append(frame, byte(n))
	case n < 1<<16:
		frame = append(frame, 126, byte(n>>8), byte(n))
	default:
		frame = append(frame, 127)
		frame = binary.BigEndian.AppendUint64(frame, uint64(n))
	}
	_, err := c.Conn.Write(append(frame, payload...))
	return err
}
