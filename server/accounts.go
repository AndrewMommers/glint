package main

import (
	"crypto/pbkdf2"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"log"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
)

// Accounts is the player store: credentials, sessions, friends and the synced
// player profile. Two backends:
//   - JSON file (dev / LAN): PBKDF2-SHA256 passwords, hashed session tokens.
//   - Appwrite: Appwrite Auth owns passwords and sessions; player rows live in
//     TablesDB and are cached in memory, with writes persisted in the background.
type Accounts struct {
	mu     sync.Mutex
	path   string
	data   accountsFile
	online map[string]map[*Client]bool // user key -> connected clients

	aw    *Appwrite
	byAw  map[string]string // Appwrite user id -> user key
	dirty map[string]bool   // user keys waiting to be written to Appwrite
	kick  chan struct{}
}

type accountsFile struct {
	Users  map[string]*User  `json:"users"`  // key: lowercased name
	Tokens map[string]string `json:"tokens"` // sha256(token) -> user key
}

type User struct {
	Name     string          `json:"name"`
	Salt     []byte          `json:"salt"`
	Hash     []byte          `json:"hash"`
	Created  time.Time       `json:"created"`
	Friends  []string        `json:"friends"`
	Incoming []string        `json:"incoming"` // friend requests received
	Outgoing []string        `json:"outgoing"` // friend requests sent
	XP       int             `json:"xp"`
	Level    int             `json:"level"`
	Profile  json.RawMessage `json:"profile,omitempty"`

	AppwriteID string `json:"appwriteId,omitempty"`
}

const pbkdf2Iterations = 120_000

var (
	validName = regexp.MustCompile(`^[A-Za-z0-9_]{3,16}$`)

	errBadName     = errors.New("usernames are 3-16 letters, numbers or _")
	errBadPassword = errors.New("passwords need at least 8 characters")
	errTaken       = errors.New("that username is taken")
	errBadLogin    = errors.New("wrong username or password")
	errBadToken    = errors.New("your session expired, please sign in again")
	errNoUser      = errors.New("no player with that username")
	errSelf        = errors.New("you can't add yourself")
	errAlready     = errors.New("you're already friends")
	errNotFriends  = errors.New("you can only invite friends")
)

func userKey(name string) string { return strings.ToLower(strings.TrimSpace(name)) }

func OpenAccounts(dir string) (*Accounts, error) {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, err
	}
	a := &Accounts{
		path:   filepath.Join(dir, "accounts.json"),
		data:   accountsFile{Users: map[string]*User{}, Tokens: map[string]string{}},
		online: map[string]map[*Client]bool{},
	}
	b, err := os.ReadFile(a.path)
	if err == nil {
		if err := json.Unmarshal(b, &a.data); err != nil {
			return nil, err
		}
		if a.data.Users == nil {
			a.data.Users = map[string]*User{}
		}
		if a.data.Tokens == nil {
			a.data.Tokens = map[string]string{}
		}
	} else if !os.IsNotExist(err) {
		return nil, err
	}
	return a, nil
}

// save writes the store atomically. Caller holds a.mu.
func (a *Accounts) save() error {
	b, err := json.MarshalIndent(a.data, "", " ")
	if err != nil {
		return err
	}
	tmp := a.path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, a.path)
}

func hashPassword(pw string, salt []byte) []byte {
	k, _ := pbkdf2.Key(sha256.New, pw, salt, pbkdf2Iterations, 32)
	return k
}

func hashToken(t string) string {
	h := sha256.Sum256([]byte(t))
	return hex.EncodeToString(h[:])
}

// issueToken creates a session token for user key k. Caller holds a.mu.
func (a *Accounts) issueToken(k string) string {
	b := make([]byte, 32)
	rand.Read(b)
	t := hex.EncodeToString(b)
	a.data.Tokens[hashToken(t)] = k
	return t
}

func (a *Accounts) Register(name, pw string) (string, *User, error) {
	if !validName.MatchString(name) {
		return "", nil, errBadName
	}
	if len(pw) < 8 || len(pw) > 128 {
		return "", nil, errBadPassword
	}
	if a.aw != nil {
		return a.registerAppwrite(name, pw)
	}
	salt := make([]byte, 16)
	rand.Read(salt)
	hash := hashPassword(pw, salt)

	a.mu.Lock()
	defer a.mu.Unlock()
	k := userKey(name)
	if _, taken := a.data.Users[k]; taken {
		return "", nil, errTaken
	}
	u := &User{Name: name, Salt: salt, Hash: hash, Created: time.Now().UTC(), Level: 1}
	a.data.Users[k] = u
	t := a.issueToken(k)
	return t, u, a.save()
}

func (a *Accounts) Login(name, pw string) (string, *User, error) {
	if a.aw != nil {
		return a.loginAppwrite(name, pw)
	}
	a.mu.Lock()
	u := a.data.Users[userKey(name)]
	a.mu.Unlock()
	if u == nil {
		hashPassword(pw, make([]byte, 16)) // keep timing similar
		return "", nil, errBadLogin
	}
	if subtle.ConstantTimeCompare(hashPassword(pw, u.Salt), u.Hash) != 1 {
		return "", nil, errBadLogin
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	t := a.issueToken(userKey(name))
	return t, u, a.save()
}

func (a *Accounts) Resume(token string) (*User, error) {
	if a.aw != nil {
		return a.resumeAppwrite(token)
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	k, ok := a.data.Tokens[hashToken(token)]
	if !ok || a.data.Users[k] == nil {
		return nil, errBadToken
	}
	return a.data.Users[k], nil
}

// Info returns a consistent snapshot of a user's public data.
func (a *Accounts) Info(k string) (name string, xp int, data json.RawMessage) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if u := a.data.Users[k]; u != nil {
		return u.Name, u.XP, u.Profile
	}
	return "", 0, nil
}

func (a *Accounts) Logout(token string) {
	if a.aw != nil {
		go a.aw.DeleteSession(token)
		return
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	delete(a.data.Tokens, hashToken(token))
	a.save()
}

// PushProfile stores the player's synced profile unless it would roll back XP.
func (a *Accounts) PushProfile(k string, xp, level int, profile json.RawMessage) {
	if len(profile) > 64*1024 {
		return
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	u := a.data.Users[k]
	if u == nil || xp < u.XP {
		return
	}
	u.XP, u.Level, u.Profile = xp, clamp(level, 1, 999), profile
	a.commit(k)
}

// ---- presence ----

func (a *Accounts) SetOnline(k string, c *Client, on bool) {
	a.mu.Lock()
	set := a.online[k]
	if on {
		if set == nil {
			set = map[*Client]bool{}
			a.online[k] = set
		}
		set[c] = true
	} else if set != nil {
		delete(set, c)
		if len(set) == 0 {
			delete(a.online, k)
		}
	}
	friends := []string{}
	if u := a.data.Users[k]; u != nil {
		friends = append(friends, u.Friends...)
	}
	a.mu.Unlock()
	for _, f := range friends {
		a.PushFriends(f)
	}
}

// notify sends v to every connection of user k. Caller must NOT hold a.mu.
func (a *Accounts) notify(k string, v any) {
	a.mu.Lock()
	clients := make([]*Client, 0, len(a.online[k]))
	for c := range a.online[k] {
		clients = append(clients, c)
	}
	a.mu.Unlock()
	for _, c := range clients {
		c.send(v)
	}
}

// ---- friends ----

type friendJ struct {
	Name   string `json:"name"`
	Online bool   `json:"online"`
	Room   string `json:"room,omitempty"`
	Level  int    `json:"level"`
}

func (a *Accounts) FriendsPayload(k string) map[string]any {
	a.mu.Lock()
	defer a.mu.Unlock()
	u := a.data.Users[k]
	out := map[string]any{"t": "friends", "friends": []friendJ{}, "incoming": []string{}, "outgoing": []string{}}
	if u == nil {
		return out
	}
	list := []friendJ{}
	for _, fk := range u.Friends {
		f := a.data.Users[fk]
		if f == nil {
			continue
		}
		fj := friendJ{Name: f.Name, Level: f.Level}
		for c := range a.online[fk] {
			fj.Online = true
			if code := c.roomCode(); code != "" {
				fj.Room = code
			}
		}
		list = append(list, fj)
	}
	sort.Slice(list, func(i, j int) bool {
		if list[i].Online != list[j].Online {
			return list[i].Online
		}
		return strings.ToLower(list[i].Name) < strings.ToLower(list[j].Name)
	})
	names := func(keys []string) []string {
		r := []string{}
		for _, x := range keys {
			if f := a.data.Users[x]; f != nil {
				r = append(r, f.Name)
			}
		}
		return r
	}
	out["friends"] = list
	out["incoming"] = names(u.Incoming)
	out["outgoing"] = names(u.Outgoing)
	return out
}

func (a *Accounts) PushFriends(k string) {
	a.notify(k, a.FriendsPayload(k))
}

func remove(list []string, x string) []string {
	out := list[:0]
	for _, v := range list {
		if v != x {
			out = append(out, v)
		}
	}
	return out
}

func contains(list []string, x string) bool {
	for _, v := range list {
		if v == x {
			return true
		}
	}
	return false
}

// AddFriend sends a request, or accepts one if the other player already asked.
func (a *Accounts) AddFriend(me, other string) (string, error) {
	ok := userKey(other)
	a.mu.Lock()
	u, o := a.data.Users[me], a.data.Users[ok]
	switch {
	case o == nil:
		a.mu.Unlock()
		return "", errNoUser
	case ok == me:
		a.mu.Unlock()
		return "", errSelf
	case contains(u.Friends, ok):
		a.mu.Unlock()
		return "", errAlready
	}
	status := "requested"
	if contains(u.Incoming, ok) {
		a.befriend(u, me, o, ok)
		status = "accepted"
	} else if !contains(u.Outgoing, ok) {
		u.Outgoing = append(u.Outgoing, ok)
		o.Incoming = append(o.Incoming, me)
	}
	a.commit(me, ok)
	name, oname := u.Name, o.Name
	a.mu.Unlock()
	a.PushFriends(me)
	a.PushFriends(ok)
	if status == "requested" {
		a.notify(ok, map[string]any{"t": "notice", "kind": "friend_request", "from": name, "msg": name + " sent you a friend request"})
	} else {
		a.notify(ok, map[string]any{"t": "notice", "kind": "friend_added", "from": name, "msg": name + " is now your friend"})
	}
	_ = oname
	return status, nil
}

// befriend links two users. Caller holds a.mu.
func (a *Accounts) befriend(u *User, uk string, o *User, ok string) {
	u.Incoming, u.Outgoing = remove(u.Incoming, ok), remove(u.Outgoing, ok)
	o.Incoming, o.Outgoing = remove(o.Incoming, uk), remove(o.Outgoing, uk)
	if !contains(u.Friends, ok) {
		u.Friends = append(u.Friends, ok)
	}
	if !contains(o.Friends, uk) {
		o.Friends = append(o.Friends, uk)
	}
}

func (a *Accounts) Accept(me, other string) error {
	ok := userKey(other)
	a.mu.Lock()
	u, o := a.data.Users[me], a.data.Users[ok]
	if o == nil || !contains(u.Incoming, ok) {
		a.mu.Unlock()
		return errNoUser
	}
	a.befriend(u, me, o, ok)
	a.commit(me, ok)
	name := u.Name
	a.mu.Unlock()
	a.PushFriends(me)
	a.PushFriends(ok)
	a.notify(ok, map[string]any{"t": "notice", "kind": "friend_added", "from": name, "msg": name + " accepted your friend request"})
	return nil
}

// Unlink removes a friendship and any pending request in either direction.
func (a *Accounts) Unlink(me, other string) {
	ok := userKey(other)
	a.mu.Lock()
	u, o := a.data.Users[me], a.data.Users[ok]
	if u != nil {
		u.Friends, u.Incoming, u.Outgoing = remove(u.Friends, ok), remove(u.Incoming, ok), remove(u.Outgoing, ok)
	}
	if o != nil {
		o.Friends, o.Incoming, o.Outgoing = remove(o.Friends, me), remove(o.Incoming, me), remove(o.Outgoing, me)
	}
	a.commit(me, ok)
	a.mu.Unlock()
	a.PushFriends(me)
	a.PushFriends(ok)
}

// RoomOf returns the room code any of the user's connections is in.
func (a *Accounts) RoomOf(k string) string {
	a.mu.Lock()
	defer a.mu.Unlock()
	for c := range a.online[k] {
		if code := c.roomCode(); code != "" {
			return code
		}
	}
	return ""
}

func (a *Accounts) AreFriends(me, other string) bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	u := a.data.Users[me]
	return u != nil && contains(u.Friends, userKey(other))
}

// ---- Appwrite backend ----

// OpenAccountsAppwrite loads every player row into memory and starts the
// background writer.
func OpenAccountsAppwrite(aw *Appwrite) (*Accounts, error) {
	a := &Accounts{
		data:   accountsFile{Users: map[string]*User{}, Tokens: map[string]string{}},
		online: map[string]map[*Client]bool{},
		aw:     aw,
		byAw:   map[string]string{},
		dirty:  map[string]bool{},
		kick:   make(chan struct{}, 1),
	}
	rows, err := aw.ListAllRows("players")
	if err != nil {
		return nil, err
	}
	for _, row := range rows {
		k, _ := row["$id"].(string)
		u := rowToUser(row)
		if k == "" || u.AppwriteID == "" {
			continue
		}
		a.data.Users[k] = u
		a.byAw[u.AppwriteID] = k
	}
	a.path = aw.Endpoint + " project " + aw.Project
	go a.writer()
	return a, nil
}

// commit persists the given users. Caller holds a.mu.
func (a *Accounts) commit(keys ...string) error {
	if a.aw == nil {
		return a.save()
	}
	for _, k := range keys {
		a.dirty[k] = true
	}
	select {
	case a.kick <- struct{}{}:
	default:
	}
	return nil
}

// writer writes dirty players to Appwrite in the background, coalescing
// bursts of changes and retrying failures.
func (a *Accounts) writer() {
	for range a.kick {
		a.mu.Lock()
		batch := map[string]map[string]any{}
		for k := range a.dirty {
			if u := a.data.Users[k]; u != nil {
				batch[k] = userRow(u)
			}
		}
		a.dirty = map[string]bool{}
		a.mu.Unlock()
		failed := false
		for k, row := range batch {
			if err := a.aw.UpdateRow("players", k, row); err != nil {
				log.Printf("appwrite: saving %s: %v", k, err)
				a.mu.Lock()
				a.dirty[k] = true
				a.mu.Unlock()
				failed = true
			}
		}
		if failed {
			time.AfterFunc(5*time.Second, func() {
				select {
				case a.kick <- struct{}{}:
				default:
				}
			})
		}
	}
}

func userRow(u *User) map[string]any {
	nz := func(s []string) []string {
		if s == nil {
			return []string{}
		}
		return s
	}
	return map[string]any{
		"name": u.Name, "appwriteId": u.AppwriteID,
		"friends": nz(u.Friends), "incoming": nz(u.Incoming), "outgoing": nz(u.Outgoing),
		"xp": u.XP, "level": u.Level, "profile": string(u.Profile),
	}
}

func rowToUser(row map[string]any) *User {
	strs := func(v any) []string {
		var out []string
		if arr, ok := v.([]any); ok {
			for _, x := range arr {
				if s, ok := x.(string); ok {
					out = append(out, s)
				}
			}
		}
		return out
	}
	num := func(v any) int {
		f, _ := v.(float64)
		return int(f)
	}
	u := &User{Friends: strs(row["friends"]), Incoming: strs(row["incoming"]), Outgoing: strs(row["outgoing"]),
		XP: num(row["xp"]), Level: num(row["level"])}
	u.Name, _ = row["name"].(string)
	u.AppwriteID, _ = row["appwriteId"].(string)
	if p, _ := row["profile"].(string); p != "" && json.Valid([]byte(p)) {
		u.Profile = json.RawMessage(p)
	}
	if u.Level < 1 {
		u.Level = 1
	}
	return u
}

// Appwrite logins use an email; players only have usernames, so each gets a
// stable internal address (no mail is ever sent to it).
func playerEmail(k string) string { return k + "@players.unoglass.app" }

// awUserError turns Appwrite auth errors into player-facing messages.
func awUserError(err error, fallback error) error {
	var e *awError
	if errors.As(err, &e) {
		switch {
		case e.Status == 409:
			return errTaken
		case e.Type == "user_blocked":
			return errors.New("this account has been disabled")
		case e.Type == "password_recently_used", e.Type == "password_personal_data",
			strings.Contains(e.Type, "password"):
			return errors.New(e.Message)
		case e.Status == 400 && strings.Contains(strings.ToLower(e.Message), "password"):
			return errors.New(e.Message)
		case e.Status == 401:
			return fallback
		}
	}
	log.Printf("appwrite: %v", err)
	return errors.New("the account service is unavailable, try again shortly")
}

func (a *Accounts) registerAppwrite(name, pw string) (string, *User, error) {
	k := userKey(name)
	a.mu.Lock()
	if _, taken := a.data.Users[k]; taken {
		a.mu.Unlock()
		return "", nil, errTaken
	}
	a.mu.Unlock()

	id, err := a.aw.CreateUser(name, playerEmail(k), pw)
	if err != nil {
		return "", nil, awUserError(err, errTaken)
	}
	if err := a.aw.SetLabels(id, []string{"player", "beta"}); err != nil {
		log.Printf("appwrite: labels for %s: %v", k, err)
	}
	u := &User{Name: name, AppwriteID: id, Level: 1, Created: time.Now().UTC()}
	if err := a.aw.CreateRow("players", k, userRow(u)); err != nil {
		a.aw.DeleteUser(id)
		return "", nil, awUserError(err, errTaken)
	}
	secret, _, err := a.aw.CreateSession(playerEmail(k), pw)
	if err != nil {
		return "", nil, awUserError(err, errBadLogin)
	}
	a.mu.Lock()
	a.data.Users[k] = u
	a.byAw[id] = k
	a.mu.Unlock()
	return secret, u, nil
}

func (a *Accounts) loginAppwrite(name, pw string) (string, *User, error) {
	k := userKey(name)
	secret, uid, err := a.aw.CreateSession(playerEmail(k), pw)
	if err != nil {
		return "", nil, awUserError(err, errBadLogin)
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.byAw[uid] != k || a.data.Users[k] == nil {
		go a.aw.DeleteSession(secret)
		return "", nil, errBadLogin
	}
	return secret, a.data.Users[k], nil
}

func (a *Accounts) resumeAppwrite(token string) (*User, error) {
	uid, err := a.aw.GetAccount(token)
	if err != nil {
		if s := awStatus(err); s == 401 || s == 404 {
			return nil, errBadToken
		}
		return nil, awUserError(err, errBadToken)
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	k, ok := a.byAw[uid]
	if !ok || a.data.Users[k] == nil {
		return nil, errBadToken
	}
	return a.data.Users[k], nil
}
