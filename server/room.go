package main

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"log"
	mrand "math/rand"
	"sync"
	"time"

	"github.com/AndrewMommers/glint/server/uno"
)

const (
	maxPlayers  = 8
	quickSeats  = 4                // Quick Match tables are filled with bots up to this
	quickWait   = 30 * time.Second // a lone Quick Match player waits this long before bots fill in
	quickJoin   = 8 * time.Second  // everyone gets at least this long in the lobby after someone joins
	quickFull   = 3 * time.Second  // countdown once the table is full
	rejoinGrace = 3 * time.Minute  // how long a room with only dropped players stays open
)

var botNames = []string{"Nova", "Pixel", "Echo", "Luna", "Orbit", "Zephyr", "Iris", "Atlas", "Mochi", "Blitz", "Juno", "Kiwi"}

var emotes = map[string]bool{"GG": true, "Nice!": true, "Oops": true, "Hurry up!": true, "Wow": true, "GLINT? ✨": true, "Good luck": true, "Haha": true}

type seat struct {
	id     string
	name   string
	client *Client // nil for bots, and for players who dropped out (away)
	diff   uno.Difficulty
	score  int
	prof   profile
	token  string      // lets a player who dropped out reclaim this seat
	away   bool        // dropped out mid-game; a bot plays until they rejoin
	ready  bool        // lobby ready check
	ban    string      // what keeps them out if the host kicks them (account or IP)
	chat   []time.Time // recent chat messages, for the rate limit
}

func (s *seat) bot() bool { return s.client == nil }

// Room owns one table. All of its state is touched only from its own
// goroutine; everything else talks to it through post/do.
type Room struct {
	code    string
	hub     *Hub
	actions chan func()
	closed  chan struct{}
	once    sync.Once

	seats       []*seat
	host        string
	phase       string
	settings    settings
	game        *uno.Game
	rng         *mrand.Rand
	gen         int // bumped on every state change; stale timers compare against it
	deadline    time.Time
	round       int
	match       int // increments for every new match, so (match, round) is unique per room
	roundPoints int
	winner      string
	quick       bool            // Quick Match room: standard rules, starts by itself
	startAt     time.Time       // Quick Match countdown (zero when not counting down)
	chat        []chatJ         // recent chat, replayed to anyone who joins
	banned      map[string]bool // ban keys of kicked players
}

func newRoom(code string, hub *Hub, seed int64) *Room {
	r := &Room{
		code:    code,
		hub:     hub,
		actions: make(chan func(), 128),
		closed:  make(chan struct{}),
		phase:   "lobby",
		rng:     mrand.New(mrand.NewSource(seed)),
		settings: settings{
			Rules: uno.DefaultRules(), TurnTime: 30, TargetScore: 500,
			Difficulty: "normal", Public: true, MaxPlayers: maxPlayers,
		},
	}
	go r.loop()
	return r
}

func (r *Room) loop() {
	for {
		select {
		case f := <-r.actions:
			r.safe(f)
		case <-r.closed:
			return
		}
	}
}

func (r *Room) safe(f func()) {
	defer func() {
		if e := recover(); e != nil {
			log.Printf("room %s: panic: %v", r.code, e)
		}
	}()
	f()
}

func (r *Room) post(f func()) {
	select {
	case r.actions <- f:
	case <-r.closed:
	}
}

// do runs f on the room goroutine and waits for it. It returns false if the
// room has already shut down.
func (r *Room) do(f func()) bool {
	done := make(chan struct{})
	select {
	case r.actions <- func() { defer close(done); f() }:
	case <-r.closed:
		return false
	}
	select {
	case <-done:
		return true
	case <-r.closed:
		return false
	}
}

func (r *Room) close() {
	r.once.Do(func() {
		close(r.closed)
		r.hub.remove(r.code)
		log.Printf("room %s closed", r.code)
	})
}

// after runs f on the room goroutine after d, unless the state changed since.
func (r *Room) after(d time.Duration, f func()) {
	gen := r.gen
	time.AfterFunc(d, func() {
		r.post(func() {
			if r.gen == gen {
				f()
			}
		})
	})
}

// ---- seats ----

func (r *Room) seatIndex(id string) int {
	for i, s := range r.seats {
		if s.id == id {
			return i
		}
	}
	return -1
}

// seatOf finds the seat c is playing in. Seats keep their id when a bot
// takes over, so clients are matched by connection, not id.
func (r *Room) seatOf(c *Client) int {
	for i, s := range r.seats {
		if s.client == c {
			return i
		}
	}
	return -1
}

func newToken() string {
	b := make([]byte, 16)
	rand.Read(b)
	return hex.EncodeToString(b)
}

// humans counts connected players (not bots, not players who dropped out).
func (r *Room) humans() int {
	n := 0
	for _, s := range r.seats {
		if !s.bot() {
			n++
		}
	}
	return n
}

func (r *Room) join(c *Client) error {
	if r.banned[c.banKey()] {
		return errors.New("the host removed you from that room")
	}
	if r.phase != "lobby" {
		return errors.New("that game has already started")
	}
	if len(r.seats) >= r.settings.MaxPlayers {
		return errors.New("that room is full")
	}
	s := &seat{id: c.id, name: c.name, client: c, prof: c.prof, token: newToken(), ban: c.banKey()}
	r.seats = append(r.seats, s)
	if r.host == "" {
		r.host = c.id
	}
	r.welcome(c, s)
	r.sysChat(s.name + " joined")
	r.armQuick()
	return nil
}

// welcome gives a (re)joining player their rejoin token and the chat so far.
func (r *Room) welcome(c *Client, s *seat) {
	c.send(map[string]any{"t": "seat", "code": r.code, "token": s.token, "id": s.id})
	items := r.chat
	if items == nil {
		items = []chatJ{}
	}
	c.send(map[string]any{"t": "chat_history", "items": items})
}

// rejoin puts a player who dropped out back into their seat.
func (r *Room) rejoin(c *Client, token string) error {
	for _, s := range r.seats {
		if token == "" || s.token != token {
			continue
		}
		if s.client == c {
			return nil
		}
		if old := s.client; old != nil {
			// The old connection hasn't noticed it's dead yet; this one wins.
			old.shutdown()
		}
		s.client, s.away = c, false
		c.id = s.id
		c.name = s.name
		r.welcome(c, s)
		r.sysChat(s.name + " is back")
		r.migrateHost()
		r.changed(nil, false)
		return nil
	}
	return errors.New("your seat in that game is gone")
}

// leave takes c out of the room. dropped means the connection was lost rather
// than the player choosing to leave: mid-game, their seat is kept for them.
func (r *Room) leave(c *Client, dropped bool) {
	i := r.seatOf(c)
	if i < 0 {
		return
	}
	s := r.seats[i]
	switch {
	case r.phase == "lobby":
		r.seats = append(r.seats[:i], r.seats[i+1:]...)
		r.sysChat(s.name + " left")
	case dropped:
		s.client, s.away, s.diff = nil, true, uno.Normal
		r.sysChat(s.name + " lost connection. A bot plays for them until they're back")
	default:
		r.sysChat(s.name + " left. A bot takes over")
		s.client, s.away, s.token, s.diff = nil, false, "", uno.Normal
		s.name += " (bot)"
	}
	if r.humans() == 0 {
		if !r.anyAway() {
			r.close()
			return
		}
		// Everyone dropped: the game waits (bots don't play on) and the room
		// stays open for a while so they can come back.
		time.AfterFunc(rejoinGrace, func() {
			r.post(func() {
				if r.humans() == 0 {
					r.close()
				}
			})
		})
	}
	r.migrateHost()
	r.changed(nil, false)
}

func (r *Room) anyAway() bool {
	for _, s := range r.seats {
		if s.away {
			return true
		}
	}
	return false
}

// migrateHost hands the host role to a connected player if the host isn't one.
func (r *Room) migrateHost() {
	if i := r.seatIndex(r.host); i >= 0 && r.seats[i].client != nil {
		return
	}
	for _, o := range r.seats {
		if o.client != nil {
			if r.host != "" && r.host != o.id {
				r.sysChat(o.name + " is now the host")
			}
			r.host = o.id
			return
		}
	}
}

// kick removes seat j. Humans can't come back; mid-game a bot takes the seat.
func (r *Room) kick(j int) error {
	s := r.seats[j]
	if s.client == nil && !s.away {
		if r.phase != "lobby" {
			return errors.New("bots can only be removed in the lobby")
		}
		r.seats = append(r.seats[:j], r.seats[j+1:]...)
		r.armQuick()
		r.changed(nil, false)
		return nil
	}
	if s.client != nil {
		s.client.send(map[string]any{"t": "kicked", "msg": "The host removed you from the room."})
		s.client.roomCode_.Store("")
	}
	if r.banned == nil {
		r.banned = map[string]bool{}
	}
	r.banned[s.ban] = true
	r.sysChat(s.name + " was removed by the host")
	if r.phase == "lobby" {
		r.seats = append(r.seats[:j], r.seats[j+1:]...)
	} else {
		s.client, s.away, s.token, s.diff = nil, false, "", uno.Normal
		s.name += " (bot)"
	}
	r.changed(nil, false)
	return nil
}

func (r *Room) addBot(diff uno.Difficulty) error {
	if r.phase != "lobby" {
		return errors.New("bots can only be added in the lobby")
	}
	if len(r.seats) >= r.settings.MaxPlayers {
		return errors.New("the table is full")
	}
	used := map[string]bool{}
	for _, s := range r.seats {
		used[s.name] = true
	}
	name := fmt.Sprintf("Bot %d", len(r.seats)+1)
	for _, i := range r.rng.Perm(len(botNames)) {
		if !used[botNames[i]] {
			name = botNames[i]
			break
		}
	}
	backs := []string{"classic", "midnight", "sunset", "aurora", "neon", "galaxy"}
	prof := profile{
		Back:  backs[r.rng.Intn(len(backs))],
		Level: [...]int{3, 12, 28}[diff] + r.rng.Intn(8),
	}
	r.seats = append(r.seats, &seat{id: r.hub.newID("b"), name: name, diff: diff, prof: prof})
	return nil
}

// ---- Quick Match ----

// armQuick (re)starts the Quick Match countdown after the lobby changed.
func (r *Room) armQuick() {
	if !r.quick || r.phase != "lobby" {
		return
	}
	now := time.Now()
	switch {
	case len(r.seats) >= r.settings.MaxPlayers:
		r.startAt = now.Add(quickFull)
	case r.startAt.IsZero():
		r.startAt = now.Add(quickWait)
	case r.startAt.Sub(now) < quickJoin:
		r.startAt = now.Add(quickJoin)
	}
	at := r.startAt
	time.AfterFunc(time.Until(at), func() {
		r.post(func() {
			if r.quick && r.phase == "lobby" && r.startAt.Equal(at) {
				r.quickStart()
			}
		})
	})
}

func (r *Room) quickStart() {
	for len(r.seats) < quickSeats {
		if r.addBot(uno.Normal) != nil {
			break
		}
	}
	r.startAt = time.Time{}
	if err := r.start(); err != nil {
		log.Printf("room %s: quick start: %v", r.code, err)
	}
}

// ---- chat ----

type chatOut struct {
	T string `json:"t"`
	chatJ
}

func (r *Room) addChat(m chatJ) {
	r.chat = append(r.chat, m)
	if len(r.chat) > chatHistory {
		r.chat = r.chat[len(r.chat)-chatHistory:]
	}
	r.broadcastRaw(chatOut{T: "chat", chatJ: m})
}

func (r *Room) sysChat(text string) { r.addChat(chatJ{Text: text, Sys: true}) }

// ---- messages ----

func (r *Room) handle(c *Client, m inMsg) {
	i := r.seatOf(c)
	if i < 0 {
		return
	}
	isHost := r.seats[i].id == r.host
	var err error
	switch m.T {
	case "settings":
		if r.quick {
			err = errors.New("Quick Match tables use the standard rules")
			break
		}
		if !isHost || r.phase == "playing" {
			err = errors.New("only the host can change settings between rounds")
			break
		}
		r.settings.apply(m.Settings)
		r.changed(nil, false)
	case "add_bot":
		if !isHost {
			err = errors.New("only the host can add bots")
			break
		}
		d := r.settings.Difficulty
		if m.Difficulty != "" {
			d = m.Difficulty
		}
		if err = r.addBot(uno.ParseDifficulty(d)); err == nil {
			r.changed(nil, false)
		}
	case "remove_bot":
		j := r.seatIndex(m.Target)
		if !isHost || r.phase != "lobby" || j < 0 || !r.seats[j].bot() {
			err = errors.New("can't remove that player")
			break
		}
		r.seats = append(r.seats[:j], r.seats[j+1:]...)
		r.armQuick()
		r.changed(nil, false)
	case "start":
		if !isHost {
			err = errors.New("only the host can start the game")
			break
		}
		if r.phase == "lobby" && r.quick {
			r.quickStart()
			break
		}
		if r.phase == "lobby" {
			for _, s := range r.seats {
				if s.client != nil && s.id != r.host && !s.ready {
					err = fmt.Errorf("waiting for %s to get ready", s.name)
					break
				}
			}
			if err != nil {
				break
			}
		}
		err = r.start()
	case "ready":
		if r.phase == "lobby" && r.seats[i].ready != m.Ready {
			r.seats[i].ready = m.Ready
			r.changed(nil, false)
		}
	case "kick":
		j := r.seatIndex(m.Target)
		if !isHost || j < 0 || j == i {
			err = errors.New("can't remove that player")
			break
		}
		err = r.kick(j)
	case "make_host":
		j := r.seatIndex(m.Target)
		if !isHost || j < 0 || j == i || r.seats[j].client == nil {
			err = errors.New("can't make that player the host")
			break
		}
		r.host = r.seats[j].id
		r.sysChat(r.seats[j].name + " is now the host")
		r.changed(nil, false)
	case "chat":
		s := r.seats[i]
		text := cleanChat(m.Text)
		if text == "" {
			break
		}
		var ok bool
		if s.chat, ok = allowChat(s.chat, time.Now()); !ok {
			err = errors.New("you're sending messages too fast")
			break
		}
		r.addChat(chatJ{Player: s.id, Name: s.name, Text: text})
	case "emote":
		if emotes[m.Text] {
			r.broadcastRaw(map[string]any{"t": "emote", "player": c.id, "text": m.Text})
		}
	default:
		err = r.gameAction(i, m)
	}
	if err != nil {
		c.send(map[string]any{"t": "error", "msg": err.Error()})
	}
}

func (r *Room) start() error {
	switch r.phase {
	case "playing":
		return errors.New("a round is already running")
	case "gameover":
		for _, s := range r.seats {
			s.score = 0
		}
		r.round = 0
	}
	if r.round == 0 {
		r.match++
	}
	if len(r.seats) < 2 {
		return errors.New("add a bot or wait for another player first")
	}
	r.game = uno.New(len(r.seats), r.round%len(r.seats), r.settings.Rules, r.rng)
	r.round++
	r.phase = "playing"
	r.winner = ""
	r.roundPoints = 0
	r.changed(nil, true)
	return nil
}

func (r *Room) gameAction(i int, m inMsg) error {
	if r.phase != "playing" {
		return errors.New("no round is running")
	}
	g := r.game
	var ev []uno.Event
	var err error
	resetTimer := true
	switch m.T {
	case "play":
		color, _ := uno.ParseColor(m.Color)
		target := -1
		if m.Target != "" {
			if target = r.seatIndex(m.Target); target < 0 {
				return uno.ErrBadTarget
			}
		}
		ev, err = g.Play(i, m.Card, color, target, m.Uno)
	case "draw":
		ev, err = g.DrawCard(i)
	case "pass":
		ev, err = g.Pass(i)
	case "uno":
		ev, err = g.DeclareUno(i)
		resetTimer = false
	case "catch":
		ev, err = g.Catch(i)
		resetTimer = false
	default:
		return fmt.Errorf("unknown message %q", m.T)
	}
	if err != nil {
		return err
	}
	r.changed(ev, resetTimer)
	return nil
}

// ---- state changes & scheduling ----

func (r *Room) changed(ev []uno.Event, resetTimer bool) {
	r.gen++
	if r.phase == "playing" && r.game.Winner >= 0 {
		w := r.seats[r.game.Winner]
		r.roundPoints = r.game.RoundPoints()
		w.score += r.roundPoints
		r.winner = w.id
		r.phase = "roundover"
		if r.settings.TargetScore == 0 || w.score >= r.settings.TargetScore {
			r.phase = "gameover"
		}
	}
	if r.phase == "playing" && (resetTimer || r.deadline.IsZero()) {
		r.deadline = time.Time{}
		if !r.seats[r.game.Turn].bot() && r.settings.TurnTime > 0 {
			r.deadline = time.Now().Add(time.Duration(r.settings.TurnTime) * time.Second)
		}
	}
	r.broadcast(ev)
	r.publishInfo()
	r.schedule()
}

func (r *Room) schedule() {
	if r.phase != "playing" || r.humans() == 0 {
		return // nobody's connected: wait for someone to rejoin
	}
	g := r.game
	turn := r.seats[g.Turn]
	if turn.bot() {
		r.after(uno.BotThinkDelay(r.rng), r.botTurn)
	} else if !r.deadline.IsZero() {
		r.after(time.Until(r.deadline), func() {
			ev, err := g.Timeout(g.Turn)
			if err == nil {
				r.changed(append([]uno.Event{{Kind: "timeout", Player: g.Turn, Target: -1}}, ev...), true)
			}
		})
	}
	// Bots watching for a missed GLINT call or a jump-in chance.
	for i, s := range r.seats {
		if !s.bot() {
			continue
		}
		i, s := i, s
		if g.CatchableBy(i) {
			if ok, d := uno.BotReaction(s.diff, r.rng); ok {
				r.after(d, func() {
					if ev, err := g.Catch(i); err == nil {
						r.changed(ev, false)
					}
				})
			}
		}
		if i != g.Turn {
			if opts := g.PlayableCards(i); len(opts) > 0 {
				if ok, d := uno.BotReaction(s.diff, r.rng); ok {
					card := opts[0]
					r.after(d, func() {
						if ev, err := g.Play(i, card.ID, uno.BestColor(g.Players[i].Hand, card.ID), -1, true); err == nil {
							r.changed(ev, true)
						}
					})
				}
			}
		}
	}
}

func (r *Room) botTurn() {
	g := r.game
	i := g.Turn
	m := uno.BotMove(g, i, r.seats[i].diff, r.rng)
	var ev []uno.Event
	var err error
	switch m.Kind {
	case "play":
		ev, err = g.Play(i, m.CardID, m.Color, m.Target, m.Uno)
	case "draw":
		ev, err = g.DrawCard(i)
	default:
		ev, err = g.Pass(i)
	}
	if err != nil { // shouldn't happen, but never stall the table
		log.Printf("room %s: bot %s: %v", r.code, m.Kind, err)
		ev, err = g.Timeout(i)
		if err != nil {
			return
		}
	}
	r.changed(ev, true)
}

// ---- output ----

func (r *Room) idAt(i int) string {
	if i < 0 || i >= len(r.seats) {
		return ""
	}
	return r.seats[i].id
}

func (r *Room) stateFor(viewer int, ev []uno.Event) stateJ {
	st := stateJ{
		T: "state", Code: r.code, Phase: r.phase, You: r.idAt(viewer), Host: r.host,
		Settings: r.settings, Round: r.round, Match: r.match, Drawn: -1, Hand: []cardJ{}, Playable: []int{},
		Events: []eventJ{}, Winner: r.winner, RoundPoints: r.roundPoints, Dir: 1, Quick: r.quick,
	}
	if r.quick && r.phase == "lobby" && !r.startAt.IsZero() {
		st.StartsIn = time.Until(r.startAt).Seconds()
	}
	g := r.game
	for i, s := range r.seats {
		p := playerJ{ID: s.id, Name: s.name, Bot: s.bot() && !s.away, Host: s.id == r.host, Score: s.score,
			Back: s.prof.Back, Frame: s.prof.Frame, Level: s.prof.Level, Away: s.away, Ready: s.ready}
		if s.bot() && !s.away {
			p.Difficulty = s.diff.String()
		}
		if g != nil && r.phase != "lobby" && i < len(g.Players) {
			p.Cards = len(g.Players[i].Hand)
			p.Vulnerable = g.Players[i].Vulnerable
		}
		st.Players = append(st.Players, p)
	}
	if g == nil || r.phase == "lobby" {
		return st
	}
	top := cardJSON(g.Top())
	st.Top = &top
	st.Color = g.Color.String()
	st.Turn = r.idAt(g.Turn)
	st.Dir = g.Dir
	st.DrawPile = len(g.DrawPile)
	st.Pending = g.PendingDraw
	if !r.deadline.IsZero() {
		st.TimeLeft = time.Until(r.deadline).Seconds()
	}
	if viewer >= 0 {
		me := g.Players[viewer]
		for _, c := range me.Hand {
			st.Hand = append(st.Hand, cardJSON(c))
		}
		for _, c := range g.PlayableCards(viewer) {
			st.Playable = append(st.Playable, c.ID)
		}
		if g.Drawn != nil && g.Turn == viewer {
			st.Drawn = g.Drawn.ID
		}
		st.CanCatch = g.CatchableBy(viewer)
		st.CanUno = (me.Vulnerable && len(me.Hand) == 1) ||
			(g.Turn == viewer && len(me.Hand) == 2 && len(st.Playable) > 0 && !me.UnoDeclared)
	}
	for _, e := range ev {
		ej := eventJ{Kind: e.Kind, Player: r.idAt(e.Player), Target: r.idAt(e.Target), Count: e.Count}
		if e.Kind == "play" || e.Kind == "jumpin" {
			ej.Color = e.Color.String()
		}
		// Drawn cards are private to whoever drew them.
		if e.Card != nil && (e.Kind != "draw" || e.Player == viewer) {
			c := cardJSON(*e.Card)
			ej.Card = &c
		}
		st.Events = append(st.Events, ej)
	}
	return st
}

func (r *Room) broadcast(ev []uno.Event) {
	for i, s := range r.seats {
		if s.client != nil {
			s.client.send(r.stateFor(i, ev))
		}
	}
}

func (r *Room) broadcastRaw(v any) {
	for _, s := range r.seats {
		if s.client != nil {
			s.client.send(v)
		}
	}
}

func (r *Room) publishInfo() {
	var info *roomInfo
	if r.settings.Public && r.phase == "lobby" && len(r.seats) < r.settings.MaxPlayers {
		hostName := ""
		if i := r.seatIndex(r.host); i >= 0 {
			hostName = r.seats[i].name
		}
		info = &roomInfo{Code: r.code, Host: hostName, Players: len(r.seats), Max: r.settings.MaxPlayers, Quick: r.quick}
	}
	r.hub.setInfo(r.code, info)
}
