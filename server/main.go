// Command server is the authoritative Glint game server. Clients speak
// newline-delimited JSON over TCP (see protocol.go).
package main

import (
	"bufio"
	"crypto/tls"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
	"unicode/utf8"

	"github.com/AndrewMommers/glint/server/uno"
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

	ip           string
	pings        bool   // client sends keepalive pings, so silence means it's gone
	user         string // account key when signed in (read goroutine only)
	token        string
	fails        int
	feedbackSent int
	roomCode_    atomic.Value // string; read by the friends list
}

// banKey is what a kick bans: the account, or the address for guests.
func (c *Client) banKey() string {
	if c.user != "" {
		return "u:" + c.user
	}
	return "ip:" + c.ip
}

// pingTimeout is how long a pinging client may stay silent (it pings every 5s).
const pingTimeout = 25 * time.Second

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

func readErr(err error) string {
	if err == nil {
		return "connection closed"
	}
	return err.Error()
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
	ip, _, _ := net.SplitHostPort(conn.RemoteAddr().String())
	if !h.admit(ip) {
		conn.Close()
		return
	}
	defer h.release(ip)
	h.clients.Add(1)
	defer func() {
		h.clients.Add(-1)
		h.lastAct.Store(time.Now().Unix())
	}()
	c := &Client{id: h.newID("p"), ip: ip, name: "Player", prof: profile{Back: "classic", Level: 1}, conn: conn, out: make(chan []byte, 64), done: make(chan struct{})}
	go c.writeLoop()
	defer c.shutdown()
	c.send(map[string]any{"t": "welcome", "id": c.id, "version": Version})

	sc := bufio.NewScanner(conn)
	sc.Buffer(make([]byte, 4096), 64*1024)
	for {
		if c.pings {
			conn.SetReadDeadline(time.Now().Add(pingTimeout))
		}
		if !sc.Scan() {
			break
		}
		var m inMsg
		if err := json.Unmarshal(sc.Bytes(), &m); err != nil {
			c.send(map[string]any{"t": "error", "msg": "bad message"})
			continue
		}
		h.dispatch(c, m)
	}
	if c.room != nil {
		r := c.room
		log.Printf("%s (%s) dropped from room %s: %v", c.name, c.id, r.code, readErr(sc.Err()))
		r.post(func() { r.leave(c, true) })
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
			if h.invites != nil {
				if err := h.invites.Check(m.Invite); err != nil {
					c.fails++
					authErr(err.Error())
					return true
				}
			}
			token, _, err = a.Register(strings.TrimSpace(m.Username), m.Password)
			if err == nil && h.invites != nil {
				if err = h.invites.Consume(m.Invite, userKey(m.Username)); err != nil {
					log.Printf("invite consume after register: %v", err)
					err = nil // account exists; don't strand the player
				}
			}
		} else {
			if h.invites != nil && h.invites.Revoked(userKey(m.Username)) {
				authErr(errRevoked.Error())
				return true
			}
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
		if err == nil && h.invites != nil && h.invites.Revoked(userKey(u.Name)) {
			a.Logout(m.Token)
			err = errRevoked
		}
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
			r.do(func() { r.leave(c, false) })
			c.setRoom(nil)
		}
	}
	switch m.T {
	case "hello", "login", "register", "auth":
		if h.minClient != "" && versionLess(m.Version, h.minClient) {
			c.send(map[string]any{"t": "outdated", "min": h.minClient, "server": Version,
				"msg": "This beta build is out of date. Please download the latest version."})
			go func() { time.Sleep(500 * time.Millisecond); c.shutdown() }()
			return
		}
	case "feedback":
		h.handleFeedback(c, m)
		return
	}
	if h.accountMsg(c, m) {
		return
	}
	switch m.T {
	case "ping":
		c.pings = true
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
		if c.room == r && c.roomCode() != "" { // already in it (and not kicked)
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
	case "quick":
		if m.Name != "" && c.user == "" {
			c.name = cleanName(m.Name)
		}
		leaveRoom()
		// Try the fullest open Quick Match table; another player may grab
		// the last seat first, so fall through to the next one.
		for _, r := range h.quickRooms() {
			var err error
			if r.do(func() {
				if err = r.join(c); err == nil {
					r.changed(nil, false)
				}
			}) && err == nil {
				c.setRoom(r)
				log.Printf("%s (%s) quick-joined room %s", c.name, c.id, r.code)
				return
			}
		}
		r := h.createRoom()
		r.do(func() {
			r.quick = true
			r.settings.MaxPlayers = quickSeats
			r.settings.TurnTime = 20
			r.settings.TargetScore = 0
			r.join(c)
			r.changed(nil, false)
		})
		c.setRoom(r)
		log.Printf("%s (%s) opened quick room %s", c.name, c.id, r.code)
	case "rejoin":
		code := strings.ToUpper(strings.TrimSpace(m.Code))
		r := h.get(code)
		if r == nil {
			c.send(map[string]any{"t": "rejoin_failed", "msg": "That game has ended"})
			return
		}
		if c.room != nil && c.room != r {
			leaveRoom()
		}
		var err error
		if !r.do(func() { err = r.rejoin(c, m.Token) }) {
			err = errors.New("that game has ended")
		}
		if err != nil {
			c.send(map[string]any{"t": "rejoin_failed", "msg": err.Error()})
			return
		}
		c.setRoom(r)
		log.Printf("%s (%s) rejoined room %s", c.name, c.id, r.code)
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
	useTLS := flag.Bool("tls", false, "encrypt connections with a self-signed certificate in <data>/tls (clients pin it)")
	inviteOnly := flag.Bool("invite-only", false, "require an invite code to register (see: glint-server invites)")
	minClient := flag.String("min-client", "", "reject clients older than this version")
	collectFeedback := flag.Bool("feedback", true, "store player feedback in <data>/feedback.jsonl")
	showVersion := flag.Bool("version", false, "print the version and exit")
	awEndpoint := flag.String("appwrite-endpoint", "", "Appwrite endpoint, e.g. https://syd.cloud.appwrite.io/v1 (enables the Appwrite backend; key from $APPWRITE_API_KEY or <data>/appwrite.key)")
	awProject := flag.String("appwrite-project", "", "Appwrite project id")
	awDB := flag.String("appwrite-db", "uno", "Appwrite TablesDB database id")
	wsAddr := flag.String("ws", "", "also accept WebSocket clients (the browser version) on this address, e.g. 127.0.0.1:7780; put a TLS proxy in front")

	if len(os.Args) > 1 && os.Args[1] == "gencert" {
		// glint-server gencert DATA_DIR : create the TLS certificate if missing
		dir := "data"
		if len(os.Args) > 2 {
			dir = os.Args[2]
		}
		_, fp, err := loadOrCreateCert(filepath.Join(dir, "tls"))
		if err != nil {
			fmt.Fprintln(os.Stderr, "error:", err)
			os.Exit(1)
		}
		fmt.Println(filepath.Join(dir, "tls", "server.crt"), fp)
		return
	}
	if len(os.Args) > 1 && os.Args[1] == "appwrite-setup" {
		if err := runAppwriteSetup(os.Args[2:]); err != nil {
			fmt.Fprintln(os.Stderr, "error:", err)
			os.Exit(1)
		}
		return
	}
	if len(os.Args) > 1 && os.Args[1] == "invites" {
		if err := runInvitesCLI(os.Args[2:]); err != nil {
			fmt.Fprintln(os.Stderr, "error:", err)
			os.Exit(1)
		}
		return
	}
	flag.Parse()
	if *showVersion {
		fmt.Println(Version)
		return
	}

	ln, err := net.Listen("tcp", *addr)
	if err != nil {
		log.Fatal(err)
	}
	var tlsCfg *tls.Config
	if *useTLS {
		cfg, fp, err := loadOrCreateCert(filepath.Join(*dataDir, "tls"))
		if err != nil {
			log.Fatalf("tls: %v", err)
		}
		tlsCfg = cfg
		log.Printf("TLS on (plain allowed from this PC/LAN only); certificate %s (sha256 %s)", filepath.Join(*dataDir, "tls", "server.crt"), fp)
	}
	log.Printf("Glint server %s listening on %s", Version, ln.Addr())
	h := NewHub()
	h.minClient = *minClient
	if *inviteOnly {
		h.invites = NewInvites(*dataDir)
		log.Printf("invite-only registration (%s)", h.invites.path)
	}
	if *collectFeedback && *useAccounts {
		h.feedback = &Feedback{path: filepath.Join(*dataDir, "feedback.jsonl")}
	}
	if *useAccounts {
		var acc *Accounts
		var err error
		if *awEndpoint != "" {
			key := loadAppwriteKey(*dataDir)
			if key == "" {
				log.Fatalf("appwrite: no API key (set APPWRITE_API_KEY or put it in %s)", filepath.Join(*dataDir, "appwrite.key"))
			}
			h.appwrite = NewAppwrite(*awEndpoint, *awProject, key, *awDB)
			acc, err = OpenAccountsAppwrite(h.appwrite)
			if err != nil {
				log.Fatalf("appwrite: %v (did you run: glint-server appwrite-setup?)", err)
			}
			log.Printf("accounts: Appwrite %s (project %s, %d players)", *awEndpoint, *awProject, len(acc.data.Users))
		} else {
			acc, err = OpenAccounts(*dataDir)
			if err != nil {
				log.Fatalf("accounts: %v", err)
			}
			log.Printf("accounts enabled (%s)", acc.path)
		}
		h.accounts = acc
	}

	h.lastAct.Store(time.Now().Unix()) // idle time counts from when we're ready
	if *wsAddr != "" {
		go h.listenWS(*wsAddr)
	}

	// Save pending account changes before exiting (Ctrl+C, service stop).
	shutdown := func(why string) {
		log.Printf("%s; saving and exiting", why)
		h.accounts.Flush(15 * time.Second)
		os.Exit(0)
	}
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
	go func() { shutdown(fmt.Sprint("received ", <-sig)) }()

	if *idleExit > 0 {
		go func() {
			for range time.Tick(time.Second) {
				idle := time.Since(time.Unix(h.lastAct.Load(), 0))
				if h.clients.Load() == 0 && idle > *idleExit {
					shutdown(fmt.Sprintf("no clients for %s", *idleExit))
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
		go func(conn net.Conn) {
			if c, ok := sniff(conn, tlsCfg); ok {
				h.serve(c)
			}
		}(conn)
	}
}
