package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// fakeAppwrite emulates the Appwrite 2.3 REST endpoints the server uses.
type fakeAppwrite struct {
	mu       sync.Mutex
	key      string
	users    map[string]map[string]any // id -> {email,password,name,labels}
	sessions map[string]string         // secret -> user id
	tables   map[string]map[string]map[string]any
	columns  int
}

func newFakeAppwrite(key string) *fakeAppwrite {
	return &fakeAppwrite{key: key, users: map[string]map[string]any{}, sessions: map[string]string{},
		tables: map[string]map[string]map[string]any{}}
}

func rid() string {
	b := make([]byte, 10)
	rand.Read(b)
	return hex.EncodeToString(b)
}

func (f *fakeAppwrite) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	reply := func(code int, v any) {
		w.WriteHeader(code)
		json.NewEncoder(w).Encode(v)
	}
	fail := func(code int, typ, msg string) {
		reply(code, map[string]any{"code": code, "type": typ, "message": msg})
	}
	if r.Header.Get("X-Appwrite-Project") != "proj" {
		fail(404, "project_not_found", "no project")
		return
	}
	var body map[string]any
	json.NewDecoder(r.Body).Decode(&body)
	p := strings.TrimPrefix(r.URL.Path, "/v1")
	session := r.Header.Get("X-Appwrite-Session")
	hasKey := r.Header.Get("X-Appwrite-Key") == f.key
	parts := strings.Split(strings.Trim(p, "/"), "/")

	switch {
	case p == "/account" && r.Method == "GET":
		if uid, ok := f.sessions[session]; ok {
			reply(200, map[string]any{"$id": uid})
		} else {
			fail(401, "general_unauthorized_scope", "guests")
		}
		return
	case p == "/account/sessions/current" && r.Method == "DELETE":
		delete(f.sessions, session)
		reply(204, nil)
		return
	}
	if !hasKey {
		fail(401, "general_unauthorized_scope", "missing key")
		return
	}
	switch {
	case p == "/users" && r.Method == "POST":
		for _, u := range f.users {
			if u["email"] == body["email"] {
				fail(409, "user_already_exists", "exists")
				return
			}
		}
		if len(body["password"].(string)) < 8 {
			fail(400, "general_argument_invalid", "Invalid `password` param: Password must be at least 8 characters")
			return
		}
		id := rid()
		f.users[id] = body
		reply(201, map[string]any{"$id": id})
	case len(parts) == 3 && parts[0] == "users" && parts[2] == "labels" && r.Method == "PUT":
		f.users[parts[1]]["labels"] = body["labels"]
		reply(200, map[string]any{})
	case len(parts) == 2 && parts[0] == "users" && r.Method == "DELETE":
		delete(f.users, parts[1])
		reply(204, nil)
	case p == "/account/sessions/email" && r.Method == "POST":
		for id, u := range f.users {
			if u["email"] == body["email"] && u["password"] == body["password"] {
				secret := rid() + rid()
				f.sessions[secret] = id
				reply(201, map[string]any{"$id": rid(), "userId": id, "secret": secret})
				return
			}
		}
		fail(401, "user_invalid_credentials", "Invalid credentials")
	case p == "/tablesdb" && r.Method == "POST":
		reply(201, map[string]any{"$id": body["databaseId"]})
	case len(parts) == 3 && parts[0] == "tablesdb" && parts[2] == "tables" && r.Method == "POST":
		t := body["tableId"].(string)
		if f.tables[t] != nil {
			fail(409, "table_already_exists", "exists")
			return
		}
		f.tables[t] = map[string]map[string]any{}
		reply(201, map[string]any{"$id": t})
	case len(parts) >= 6 && parts[4] == "columns" && r.Method == "POST":
		f.columns++
		reply(202, map[string]any{"key": body["key"], "status": "processing"})
	case len(parts) == 6 && parts[4] == "columns" && r.Method == "GET":
		reply(200, map[string]any{"key": parts[5], "status": "available"})
	case len(parts) == 5 && parts[4] == "indexes":
		reply(202, map[string]any{})
	case len(parts) == 5 && parts[4] == "rows" && r.Method == "POST":
		t, id := parts[3], body["rowId"].(string)
		if id == "unique()" {
			id = rid()
		}
		if f.tables[t][id] != nil {
			fail(409, "row_already_exists", "exists")
			return
		}
		row := body["data"].(map[string]any)
		row["$id"] = id
		f.tables[t][id] = row
		reply(201, row)
	case len(parts) == 6 && parts[4] == "rows" && r.Method == "PATCH":
		row := f.tables[parts[3]][parts[5]]
		if row == nil {
			fail(404, "row_not_found", "no row")
			return
		}
		for k, v := range body["data"].(map[string]any) {
			row[k] = v
		}
		reply(200, row)
	case len(parts) == 5 && parts[4] == "rows" && r.Method == "GET":
		rows := []map[string]any{}
		for _, row := range f.tables[parts[3]] {
			rows = append(rows, row)
		}
		reply(200, map[string]any{"total": len(rows), "rows": rows})
	default:
		fail(404, "route_not_found", r.Method+" "+p)
	}
}

func (f *fakeAppwrite) row(table, id string) map[string]any {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.tables[table][id]
}

func TestAppwriteBackend(t *testing.T) {
	fake := newFakeAppwrite("secret-key")
	srv := httptest.NewServer(fake)
	defer srv.Close()
	aw := NewAppwrite(srv.URL+"/v1", "proj", "secret-key", "uno")
	if err := aw.Setup(func(string, ...any) {}); err != nil {
		t.Fatal(err)
	}
	if err := aw.Setup(func(string, ...any) {}); err != nil { // idempotent
		t.Fatalf("second setup: %v", err)
	}
	acc, err := OpenAccountsAppwrite(aw)
	if err != nil {
		t.Fatal(err)
	}

	ln, _ := net.Listen("tcp", "127.0.0.1:0")
	defer ln.Close()
	h := NewHub()
	h.accounts, h.appwrite = acc, aw
	h.feedback = &Feedback{path: t.TempDir() + "/fb.jsonl"}
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
	alice.send(map[string]any{"t": "register", "username": "Alice", "password": "short"})
	if e := alice.waitFor("auth_error"); e["msg"] != errBadPassword.Error() {
		t.Fatalf("expected password rule, got %v", e)
	}
	alice.send(map[string]any{"t": "register", "username": "Alice", "password": "hunter2222"})
	ok := alice.waitFor("auth_ok")
	token := ok["token"].(string)

	bob := dialTest(t, addr)
	bob.send(map[string]any{"t": "register", "username": "alice", "password": "whatever12"})
	if e := bob.waitFor("auth_error"); e["msg"] != errTaken.Error() {
		t.Fatalf("expected taken, got %v", e)
	}
	bob.send(map[string]any{"t": "register", "username": "Bob", "password": "secret9999"})
	bob.waitFor("auth_ok")

	// Passwords are checked by Appwrite.
	x := dialTest(t, addr)
	x.send(map[string]any{"t": "login", "username": "bob", "password": "wrongpass1"})
	if e := x.waitFor("auth_error"); e["msg"] != errBadLogin.Error() {
		t.Fatalf("expected bad login, got %v", e)
	}
	x.send(map[string]any{"t": "login", "username": "BOB", "password": "secret9999"})
	x.waitFor("auth_ok")

	// Sessions resume through Appwrite.
	again := dialTest(t, addr)
	again.send(map[string]any{"t": "auth", "token": token})
	if m := again.waitFor("auth_ok"); m["username"] != "Alice" {
		t.Fatalf("resume: %v", m)
	}

	// Friends persist to the players table.
	alice.send(map[string]any{"t": "friend_add", "username": "bob"})
	bob.waitFor("notice")
	bob.send(map[string]any{"t": "friend_accept", "username": "alice"})
	alice.waitFor("notice")
	alice.send(map[string]any{"t": "profile_push", "xp": 420, "level": 4, "data": map[string]any{"xp": 420}})
	deadline := time.Now().Add(5 * time.Second)
	for {
		row := fake.row("players", "alice")
		fr, _ := row["friends"].([]any)
		if len(fr) == 1 && fr[0] == "bob" && row["xp"] == float64(420) {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("players row not updated: %v", row)
		}
		time.Sleep(50 * time.Millisecond)
	}

	// A fresh server loads everything back from Appwrite.
	acc2, err := OpenAccountsAppwrite(aw)
	if err != nil {
		t.Fatal(err)
	}
	if !acc2.AreFriends("alice", "bob") {
		t.Fatal("friendship not loaded from Appwrite")
	}
	if _, xp, _ := acc2.Info("alice"); xp != 420 {
		t.Fatalf("xp not loaded: %d", xp)
	}

	// Feedback goes to the feedback table too.
	alice.send(map[string]any{"t": "feedback", "category": "idea", "text": "more themes", "info": map[string]any{"version": "0.9.0-beta.2"}})
	alice.waitFor("notice")
	deadline = time.Now().Add(5 * time.Second)
	for {
		fake.mu.Lock()
		n := len(fake.tables["feedback"])
		fake.mu.Unlock()
		if n == 1 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("feedback row not created")
		}
		time.Sleep(50 * time.Millisecond)
	}

	// Logout ends the Appwrite session.
	alice.send(map[string]any{"t": "logout"})
	alice.waitFor("logged_out")
	time.Sleep(200 * time.Millisecond)
	if _, err := acc.Resume(token); err != errBadToken {
		t.Fatalf("token should be invalid after logout, got %v", err)
	}
}
