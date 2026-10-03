package main

import (
	"crypto/rand"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"text/tabwriter"
	"time"
)

// Invites are single-use beta access codes, kept in <data>/invites.json.
// The file is re-read on every use so codes created with the CLI while the
// server is running take effect immediately.
type Invites struct {
	mu   sync.Mutex
	path string
}

type invite struct {
	Code    string    `json:"code"`
	Note    string    `json:"note,omitempty"`
	Created time.Time `json:"created"`
	UsedBy  string    `json:"usedBy,omitempty"` // account key
	UsedAt  time.Time `json:"usedAt,omitempty"`
	Revoked bool      `json:"revoked,omitempty"`
}

var (
	errInviteNeeded  = errors.New("an invite code is required to join the beta")
	errInviteInvalid = errors.New("that invite code isn't valid")
	errInviteUsed    = errors.New("that invite code was already used")
	errRevoked       = errors.New("your beta access has been revoked")
)

func NewInvites(dir string) *Invites {
	return &Invites{path: filepath.Join(dir, "invites.json")}
}

func (iv *Invites) load() (map[string]*invite, error) {
	m := map[string]*invite{}
	b, err := os.ReadFile(iv.path)
	if os.IsNotExist(err) {
		return m, nil
	}
	if err != nil {
		return nil, err
	}
	return m, json.Unmarshal(b, &m)
}

func (iv *Invites) save(m map[string]*invite) error {
	b, err := json.MarshalIndent(m, "", " ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(iv.path), 0o755); err != nil {
		return err
	}
	tmp := iv.path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, iv.path)
}

func normCode(c string) string { return strings.ToUpper(strings.TrimSpace(c)) }

// Check reports whether code can be used, without consuming it.
func (iv *Invites) Check(code string) error {
	iv.mu.Lock()
	defer iv.mu.Unlock()
	m, err := iv.load()
	if err != nil {
		return err
	}
	return checkInvite(m, normCode(code))
}

func checkInvite(m map[string]*invite, code string) error {
	if code == "" {
		return errInviteNeeded
	}
	inv := m[code]
	switch {
	case inv == nil || inv.Revoked:
		return errInviteInvalid
	case inv.UsedBy != "":
		return errInviteUsed
	}
	return nil
}

// Consume marks code as used by account key user.
func (iv *Invites) Consume(code, user string) error {
	iv.mu.Lock()
	defer iv.mu.Unlock()
	m, err := iv.load()
	if err != nil {
		return err
	}
	code = normCode(code)
	if err := checkInvite(m, code); err != nil {
		return err
	}
	m[code].UsedBy, m[code].UsedAt = user, time.Now().UTC()
	return iv.save(m)
}

// Revoked reports whether the invite user registered with has been revoked.
func (iv *Invites) Revoked(user string) bool {
	iv.mu.Lock()
	defer iv.mu.Unlock()
	m, err := iv.load()
	if err != nil {
		return false
	}
	for _, inv := range m {
		if inv.UsedBy == user && inv.Revoked {
			return true
		}
	}
	return false
}

func newInviteCode() string {
	const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789" // no 0/O/1/I
	b := make([]byte, 8)
	rand.Read(b)
	out := make([]byte, 8)
	for i := range b {
		out[i] = alphabet[int(b[i])%len(alphabet)]
	}
	return "UNO-" + string(out[:4]) + "-" + string(out[4:])
}

// runInvitesCLI implements:  uno-server invites create|list|revoke ...
func runInvitesCLI(args []string) error {
	fs := flag.NewFlagSet("invites", flag.ExitOnError)
	dataDir := fs.String("data", "data", "server data directory")
	n := fs.Int("n", 1, "number of codes to create")
	note := fs.String("note", "", "note to remember who a code is for")
	usage := func() {
		fmt.Fprintln(os.Stderr, `usage:
  uno-server invites create [-n 5] [-note "Sam"] [-data DIR]
  uno-server invites list [-data DIR]
  uno-server invites revoke [-data DIR] CODE|USERNAME`)
	}
	if len(args) == 0 {
		usage()
		return errors.New("missing command")
	}
	cmd := args[0]
	fs.Parse(args[1:])
	iv := NewInvites(*dataDir)
	iv.mu.Lock()
	defer iv.mu.Unlock()
	m, err := iv.load()
	if err != nil {
		return err
	}
	switch cmd {
	case "create":
		for i := 0; i < *n; i++ {
			code := newInviteCode()
			for m[code] != nil {
				code = newInviteCode()
			}
			m[code] = &invite{Code: code, Note: *note, Created: time.Now().UTC()}
			fmt.Println(code)
		}
		return iv.save(m)
	case "list":
		list := make([]*invite, 0, len(m))
		for _, inv := range m {
			list = append(list, inv)
		}
		sort.Slice(list, func(a, b int) bool { return list[a].Created.Before(list[b].Created) })
		w := tabwriter.NewWriter(os.Stdout, 0, 2, 2, ' ', 0)
		fmt.Fprintln(w, "CODE\tSTATUS\tUSED BY\tNOTE")
		for _, inv := range list {
			status := "unused"
			if inv.UsedBy != "" {
				status = "used " + inv.UsedAt.Format("2006-01-02")
			}
			if inv.Revoked {
				status = "REVOKED"
			}
			fmt.Fprintf(w, "%s\t%s\t%s\t%s\n", inv.Code, status, inv.UsedBy, inv.Note)
		}
		return w.Flush()
	case "revoke":
		if fs.NArg() != 1 {
			usage()
			return errors.New("revoke needs a code or username")
		}
		target := fs.Arg(0)
		found := false
		for _, inv := range m {
			if inv.Code == normCode(target) || (inv.UsedBy != "" && inv.UsedBy == userKey(target)) {
				inv.Revoked = true
				found = true
				fmt.Println("revoked", inv.Code, inv.UsedBy)
			}
		}
		if !found {
			return fmt.Errorf("no invite matching %q", target)
		}
		return iv.save(m)
	}
	usage()
	return fmt.Errorf("unknown command %q", cmd)
}
