// Command server is the authoritative UNO game server. Clients speak
// newline-delimited JSON over TCP (see protocol.go).
package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"flag"
	"log"
	"net"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unicode/utf8"

	"github.com/AndrewMommers/uno-glass/server/uno"
)

type Client struct {
	id   string
	name string
	prof profile
	conn net.Conn
	out  chan []byte
	done chan struct{}
	once sync.Once
	room *Room // only touched by the client's read goroutine

	user      string // account key when signed in (read goroutine only)
	token     string
	fails     int
	roomCode_ atomic.Value // string; read by the friends list
}

func (c *Client) roomCode() string {
	s, _ := c.roomCode_.Load().(string)
	return s
}

func (c *Client) setRoom(r *Room) {
	c.room = r
	code := ""
	if r != nil {
		code = r.code
	}
	c.roomCode_.Store(code)
}

func (c *Client) send(v any) {
	b, err := json.Marshal(v)
	if err != nil {
		log.Printf("marshal: %v", err)
		return
	}
	select {
	case <-c.done:
		return
	default:
	}
	select {
	case c.out <- append(b, '\n'):
	default: // client can't keep up; drop it
		c.shutdown()
	}
}

func (c *Client) shutdown() {
	c.once.Do(func() {
		close(c.done)
		c.conn.Close()
	})
}

func (c *Client) writeLoop() {
	for {
		select {
		case b := <-c.out:
			c.conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
			if _, err := c.conn.Write(b); err != nil {
				c.shutdown()
				return
			}
		case <-c.done:
			return
		}
	}
}

func cleanName(s string) string {
	s = strings.TrimSpace(s)
	s = strings.Map(func(r rune) rune {
		if r < 32 {
			return -1
		}
		return r
	}, s)
	for utf8.RuneCountInString(s) > 16 {
		_, size := utf8.DecodeLastRuneInString(s)
		s = s[:len(s)-size]
	}
	if s == "" {
		s = "Player"
	}
	return s
}

func (h *Hub) serve(conn net.Conn) {
	h.clients.Add(1)
	defer func() {
		h.clients.Add(-1)
		h.lastAct.Store(time.Now().Unix())
	}()
	c := &Client{id: h.newID("p"), name: "Player", prof: profile{Back: "classic", Level: 1}, conn: conn, out: make(chan []byte, 64), done: make(chan struct{})}
	go c.writeLoop()
	defer c.shutdown()
	c.send(map[string]any{"t": "welcome", "id": c.id})

	sc := bufio.NewScanner(conn)
	sc.Buffer(make([]byte, 4096), 64*1024)
	for sc.Scan() {
		var m inMsg
		if err := json.Unmarshal(sc.Bytes(), &m); err != nil {
			c.send(map[string]any{"t": "error", "msg": "bad message"})
			continue
		}
		h.dispatch(c, m)
	}
	if c.room != nil {
		r := c.room
		r.post(func() { r.leave(c) })
	}
	if c.user != "" && h.accounts != nil {
		h.accounts.SetOnline(c.user, c, false)
	}
}

// signIn attaches an account to the connection and replies with auth_ok.
func (h *Hub) signIn(c *Client, k, token string, reply bool) {
	if c.user != "" && c.user != k {
		h.accounts.SetOnline(c.user, c, false)
	}
	name, xp, data := h.accounts.Info(k)
	c.user, c.token, c.name = k, token, name
	h.accounts.SetOnline(k, c, true)
	if reply {
		msg := map[string]any{"t": "auth_ok", "username": name, "token": token, "xp": xp}
		if len(data) > 0 {
			msg["data"] = data
		}
		c.send(msg)
		c.send(h.accounts.FriendsPayload(k))
	}
}

// accountMsg handles account and friends messages. Returns false if m isn't one.
func (h *Hub) accountMsg(c *Client, m inMsg) bool {
	switch m.T {
	case "register", "login", "auth", "logout", "profile_push", "friends",
		"friend_add", "friend_accept", "friend_decline", "friend_remove", "invite":
	default:
		return false
	}
	authErr := func(msg string) { c.send(map[string]any{"t": "auth_error", "msg": msg}) }
	if h.accounts == nil {
		authErr("this server doesn't support accounts")
		return true
	}
	a := h.accounts
	if (m.T == "login" || m.T == "register") && c.fails >= 8 {
		authErr("too many attempts, reconnect and try again")
		return true
	}
	switch m.T {
	case "register", "login":
		var token string
		var err error
		if m.T == "register" {
			token, _, err = a.Register(strings.TrimSpace(m.Username), m.Password)
		} else {
			token, _, err = a.Login(strings.TrimSpace(m.Username), m.Password)
		}
		if err != nil {
			c.fails++
			authErr(err.Error())
			return true
		}
		h.signIn(c, userKey(m.Username), token, true)
		log.Printf("%s signed in (%s)", c.name, m.T)
		return true
	case "auth":
		u, err := a.Resume(m.Token)
		if err != nil {
			c.send(map[string]any{"t": "auth_expired", "msg": err.Error()})
			return true
		}
		h.signIn(c, userKey(u.Name), m.Token, true)
		return true
	}
	if c.user == "" {
		authErr("sign in first")
		return true
	}
	fail := func(err error) { c.send(map[string]any{"t": "error", "msg": err.Error()}) }
	switch m.T {
	case "logout":
		a.Logout(c.token)
		a.SetOnline(c.user, c, false)
		c.user, c.token = "", ""
		c.send(map[string]any{"t": "logged_out"})
	case "profile_push":
		a.PushProfile(c.user, m.XP, m.Level, m.Data)
	case "friends":
		c.send(a.FriendsPayload(c.user))
	case "friend_add":
		if st, err := a.AddFriend(c.user, m.Username); err != nil {
			fail(err)
		} else if st == "requested" {
			c.send(map[string]any{"t": "notice", "kind": "info", "msg": "Friend request sent to " + strings.TrimSpace(m.Username)})
		}
	case "friend_accept":
		if err := a.Accept(c.user, m.Username); err != nil {
			fail(err)
		}
	case "friend_decline", "friend_remove":
		a.Unlink(c.user, m.Username)
	case "invite":
		code := a.RoomOf(c.user)
		if code == "" {
			fail(errors.New("join or create a room first"))
		} else if !a.AreFriends(c.user, m.Username) {
			fail(errNotFriends)
		} else {
			a.notify(userKey(m.Username), map[string]any{"t": "invite", "from": c.name, "code": code})
			c.send(map[string]any{"t": "notice", "kind": "info", "msg": "Invite sent to " + strings.TrimSpace(m.Username)})
		}
	}
	return true
}

func (h *Hub) dispatch(c *Client, m inMsg) {
	fail := func(msg string) { c.send(map[string]any{"t": "error", "msg": msg}) }
	leaveRoom := func() {
		if c.room != nil {
			r := c.room
			r.do(func() { r.leave(c) })
			c.setRoom(nil)
		}
	}
	if h.accountMsg(c, m) {
		return
	}
	switch m.T {
	case "ping":
		c.send(map[string]any{"t": "pong"})
	case "hello":
		if c.user == "" {
			c.name = cleanName(m.Name)
		}
		if m.Profile != nil {
			c.prof = m.Profile.clean()
		}
		// Game connections can carry the account token so rooms show the
		// account name; failures are silent here.
		if m.Token != "" && h.accounts != nil && c.user == "" {
			if u, err := h.accounts.Resume(m.Token); err == nil {
				h.signIn(c, userKey(u.Name), m.Token, false)
			}
		}
	case "list":
		c.send(map[string]any{"t": "rooms", "rooms": h.publicRooms()})
	case "create":
		if m.Name != "" && c.user == "" {
			c.name = cleanName(m.Name)
		}
		leaveRoom()
		r := h.createRoom()
		var err error
		r.do(func() {
			r.settings.apply(m.Settings)
			if err = r.join(c); err != nil {
				return
			}
			for i := 0; i < clamp(m.Bots, 0, maxPlayers-1); i++ {
				r.addBot(uno.ParseDifficulty(r.settings.Difficulty))
			}
			r.changed(nil, false)
		})
		if err != nil {
			fail(err.Error())
			return
		}
		c.setRoom(r)
		log.Printf("%s (%s) created room %s", c.name, c.id, r.code)
	case "join":
		if m.Name != "" && c.user == "" {
			c.name = cleanName(m.Name)
		}
		code := strings.ToUpper(strings.TrimSpace(m.Code))
		r := h.get(code)
		if r == nil {
			fail("no room with code " + code)
			return
		}
		if c.room == r {
			return
		}
		leaveRoom()
		var err error
		if !r.do(func() {
			if err = r.join(c); err == nil {
				r.changed(nil, false)
			}
		}) {
			fail("that room just closed")
			return
		}
		if err != nil {
			fail(err.Error())
			return
		}
		c.setRoom(r)
		log.Printf("%s (%s) joined room %s", c.name, c.id, r.code)
	case "leave":
		leaveRoom()
		c.send(map[string]any{"t": "left"})
	default:
		if c.room == nil {
			fail("you're not in a room")
			return
		}
		r := c.room
		r.post(func() { r.handle(c, m) })
	}
}

func main() {
	addr := flag.String("addr", ":7777", "address to listen on")
	dataDir := flag.String("data", "data", "directory for persistent data (accounts)")
	useAccounts := flag.Bool("accounts", true, "enable player accounts and friends")
	idleExit := flag.Duration("idle-exit", 0, "exit after this long with no connected clients (0 = never); used for singleplayer")
	flag.Parse()

	ln, err := net.Listen("tcp", *addr)
	if err != nil {
		log.Fatal(err)
	}
	log.Printf("UNO server listening on %s", ln.Addr())
	h := NewHub()
	if *useAccounts {
		acc, err := OpenAccounts(*dataDir)
		if err != nil {
			log.Fatalf("accounts: %v", err)
		}
		h.accounts = acc
		log.Printf("accounts enabled (%s)", acc.path)
	}

	if *idleExit > 0 {
		go func() {
			for range time.Tick(time.Second) {
				idle := time.Since(time.Unix(h.lastAct.Load(), 0))
				if h.clients.Load() == 0 && idle > *idleExit {
					log.Printf("no clients for %s, exiting", *idleExit)
					os.Exit(0)
				}
			}
		}()
	}

	for {
		conn, err := ln.Accept()
		if err != nil {
			log.Printf("accept: %v", err)
			continue
		}
		h.lastAct.Store(time.Now().Unix())
		go h.serve(conn)
	}
}
