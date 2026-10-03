package main

import (
	"bufio"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestVersionLess(t *testing.T) {
	cases := []struct {
		a, b string
		less bool
	}{
		{"0.9.0-beta.1", "0.9.0-beta.2", true},
		{"0.9.0-beta.2", "0.9.0-beta.10", true},
		{"0.9.0-beta.10", "0.9.0-beta.2", false},
		{"0.9.0-beta.3", "0.9.0", true},
		{"0.9.0", "0.9.0-beta.3", false},
		{"0.9.1-beta.1", "0.9.0", false},
		{"1.0.0", "0.10.0", false},
		{"", "0.1.0", true},
		{"0.9.0-beta.1", "0.9.0-beta.1", false},
	}
	for _, c := range cases {
		if got := versionLess(c.a, c.b); got != c.less {
			t.Errorf("versionLess(%q, %q) = %v, want %v", c.a, c.b, got, c.less)
		}
	}
}

// A beta server: TLS, invite-only, minimum client version and feedback.
func TestBetaServer(t *testing.T) {
	dir := t.TempDir()
	cfg, fp, err := loadOrCreateCert(filepath.Join(dir, "tls"))
	if err != nil || len(fp) != 64 {
		t.Fatalf("cert: %v %q", err, fp)
	}
	raw, _ := net.Listen("tcp", "127.0.0.1:0")
	defer raw.Close()
	h := NewHub()
	h.accounts, _ = OpenAccounts(dir)
	h.invites = NewInvites(dir)
	h.minClient = "0.9.0-beta.1"
	h.feedback = &Feedback{path: filepath.Join(dir, "feedback.jsonl")}
	go func() {
		for {
			c, err := raw.Accept()
			if err != nil {
				return
			}
			go func(c net.Conn) {
				if sc, ok := sniff(c, cfg); ok {
					h.serve(sc)
				}
			}(c)
		}
	}()

	// Plain JSON still works from this machine (same port).
	plain := dialTest(t, raw.Addr().String())
	plain.send(map[string]any{"t": "ping"})
	plain.waitFor("pong")

	// Clients pin the server certificate and verify against CertName.
	pem, _ := os.ReadFile(filepath.Join(dir, "tls", "server.crt"))
	pool := x509.NewCertPool()
	pool.AppendCertsFromPEM(pem)
	dial := func() *testConn {
		c, err := tls.Dial("tcp", raw.Addr().String(), &tls.Config{RootCAs: pool, ServerName: CertName})
		if err != nil {
			t.Fatalf("tls dial: %v", err)
		}
		sc := bufio.NewScanner(c)
		sc.Buffer(make([]byte, 4096), 1<<20)
		return &testConn{t, c, sc}
	}

	// A client that doesn't trust the cert can't connect.
	if c, err := tls.Dial("tcp", raw.Addr().String(), &tls.Config{ServerName: CertName}); err == nil {
		c.Close()
		t.Fatal("untrusted TLS handshake should fail")
	}

	// Old clients are turned away.
	old := dial()
	old.send(map[string]any{"t": "hello", "name": "Old", "version": "0.8.0"})
	if m := old.waitFor("outdated"); m["min"] != "0.9.0-beta.1" {
		t.Fatalf("bad outdated %v", m)
	}

	// Invite codes.
	if err := runInvitesCLI([]string{"create", "-n", "2", "-note", "test", "-data", dir}); err != nil {
		t.Fatal(err)
	}
	m, _ := h.invites.load()
	var codes []string
	for code := range m {
		codes = append(codes, code)
	}

	c := dial()
	c.send(map[string]any{"t": "register", "username": "Tester", "password": "pw123456", "version": Version})
	if e := c.waitFor("auth_error"); e["msg"] != errInviteNeeded.Error() {
		t.Fatalf("expected invite needed, got %v", e)
	}
	c.send(map[string]any{"t": "register", "username": "Tester", "password": "pw123456", "invite": "UNO-NOPE-NOPE", "version": Version})
	c.waitFor("auth_error")
	c.send(map[string]any{"t": "register", "username": "Tester", "password": "pw123456", "invite": strings.ToLower(codes[0]), "version": Version})
	ok := c.waitFor("auth_ok")

	c2 := dial()
	c2.send(map[string]any{"t": "register", "username": "Other", "password": "pw123456", "invite": codes[0], "version": Version})
	if e := c2.waitFor("auth_error"); e["msg"] != errInviteUsed.Error() {
		t.Fatalf("expected used, got %v", e)
	}

	// Feedback.
	c.send(map[string]any{"t": "feedback", "category": "bug", "text": "cards overlap", "info": map[string]any{"os": "Windows"}, "log": "line1\nline2"})
	if n := c.waitFor("notice"); n["kind"] != "feedback_ok" {
		t.Fatalf("feedback not acknowledged: %v", n)
	}
	fb, _ := os.ReadFile(h.feedback.path)
	var entry feedbackEntry
	if err := json.Unmarshal(fb[:len(fb)-1], &entry); err != nil || entry.Text != "cards overlap" || entry.User != "tester" {
		t.Fatalf("bad feedback entry %s (%v)", fb, err)
	}

	// Revoking the code locks the account out, token included.
	if err := runInvitesCLI([]string{"revoke", "-data", dir, "tester"}); err != nil {
		t.Fatal(err)
	}
	c3 := dial()
	c3.send(map[string]any{"t": "auth", "token": ok["token"], "version": Version})
	if e := c3.waitFor("auth_expired"); e["msg"] != errRevoked.Error() {
		t.Fatalf("expected revoked, got %v", e)
	}
	c3.send(map[string]any{"t": "login", "username": "Tester", "password": "pw123456", "version": Version})
	if e := c3.waitFor("auth_error"); e["msg"] != errRevoked.Error() {
		t.Fatalf("expected revoked login, got %v", e)
	}
	_ = time.Second
}
