package main

import (
	"bufio"
	"encoding/json"
	"net"
	"testing"
	"time"
)

type testConn struct {
	t  *testing.T
	c  net.Conn
	sc *bufio.Scanner
}

func dialTest(t *testing.T, addr string) *testConn {
	c, err := net.Dial("tcp", addr)
	if err != nil {
		t.Fatal(err)
	}
	sc := bufio.NewScanner(c)
	sc.Buffer(make([]byte, 4096), 1<<20)
	return &testConn{t, c, sc}
}

func (tc *testConn) send(v map[string]any) {
	b, _ := json.Marshal(v)
	tc.c.Write(append(b, '\n'))
}

// waitFor reads messages until one of type typ arrives.
func (tc *testConn) waitFor(typ string) map[string]any {
	tc.t.Helper()
	tc.c.SetReadDeadline(time.Now().Add(5 * time.Second))
	for tc.sc.Scan() {
		var m map[string]any
		json.Unmarshal(tc.sc.Bytes(), &m)
		if m["t"] == typ {
			return m
		}
	}
	tc.t.Fatalf("no %q message: %v", typ, tc.sc.Err())
	return nil
}

func TestAccountsAndFriends(t *testing.T) {
	ln, _ := net.Listen("tcp", "127.0.0.1:0")
	defer ln.Close()
	h := NewHub()
	acc, err := OpenAccounts(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	h.accounts = acc
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go h.serve(c)
		}
	}()
	addr := ln.Addr().String()

	alice := dialTest(t, addr)
	alice.send(map[string]any{"t": "register", "username": "Alice", "password": "hunter22"})
	ok := alice.waitFor("auth_ok")
	if ok["username"] != "Alice" || ok["token"] == "" {
		t.Fatalf("bad auth_ok %v", ok)
	}
	aliceToken := ok["token"].(string)

	bob := dialTest(t, addr)
	bob.send(map[string]any{"t": "register", "username": "alice", "password": "whatever1"})
	if e := bob.waitFor("auth_error"); e["msg"] != errTaken.Error() {
		t.Fatalf("expected taken, got %v", e)
	}
	bob.send(map[string]any{"t": "register", "username": "Bob", "password": "secret99"})
	bob.waitFor("auth_ok")

	// Wrong password is rejected; right one works.
	other := dialTest(t, addr)
	other.send(map[string]any{"t": "login", "username": "bob", "password": "nope123"})
	other.waitFor("auth_error")
	other.send(map[string]any{"t": "login", "username": "bob", "password": "secret99"})
	other.waitFor("auth_ok")

	// Token resume.
	again := dialTest(t, addr)
	again.send(map[string]any{"t": "auth", "token": aliceToken})
	if m := again.waitFor("auth_ok"); m["username"] != "Alice" {
		t.Fatalf("resume failed: %v", m)
	}

	// Friend request -> accept.
	alice.send(map[string]any{"t": "friend_add", "username": "bob"})
	if n := bob.waitFor("notice"); n["kind"] != "friend_request" {
		t.Fatalf("expected friend request notice, got %v", n)
	}
	bob.send(map[string]any{"t": "friend_accept", "username": "Alice"})
	alice.waitFor("notice") // "request sent" info
	if n := alice.waitFor("notice"); n["kind"] != "friend_added" {
		t.Fatalf("expected accepted notice, got %v", n)
	}
	alice.send(map[string]any{"t": "friends"})
	fr := alice.waitFor("friends")
	list := fr["friends"].([]any)
	if len(list) != 1 || list[0].(map[string]any)["name"] != "Bob" || list[0].(map[string]any)["online"] != true {
		t.Fatalf("bad friends list %v", fr)
	}

	// Invite needs a room.
	alice.send(map[string]any{"t": "create", "bots": 1})
	alice.waitFor("state")
	alice.send(map[string]any{"t": "invite", "username": "Bob"})
	inv := bob.waitFor("invite")
	if inv["from"] != "Alice" || len(inv["code"].(string)) != 4 {
		t.Fatalf("bad invite %v", inv)
	}

	// Data survives a reload, and logout kills the token.
	alice.send(map[string]any{"t": "logout"})
	alice.waitFor("logged_out")
	reloaded, err := OpenAccounts(acc.path[:len(acc.path)-len("/accounts.json")])
	if err != nil {
		t.Fatal(err)
	}
	if !reloaded.AreFriends("alice", "bob") {
		t.Fatal("friendship not persisted")
	}
	if _, err := reloaded.Resume(aliceToken); err == nil {
		t.Fatal("token should be invalid after logout")
	}
}

func TestRegistrationLimitPerIP(t *testing.T) {
	h := NewHub()
	for i := 0; i < regsPerIP; i++ {
		if !h.allowRegistration("203.0.113.5") {
			t.Fatalf("registration %d refused", i+1)
		}
	}
	if h.allowRegistration("203.0.113.5") {
		t.Fatal("too many registrations allowed from one address")
	}
	if !h.allowRegistration("203.0.113.6") {
		t.Fatal("another address was limited")
	}
}
