package main

// Blackjack tables. A room whose kind is gameBlackjack runs rounds forever:
// betting, playing (each seat in turn), the dealer, results, then betting
// again. Players can sit down while a round is on and join the next one.
// Chips are real per-account balances (play money), saved after each round.

import (
	"errors"
	"fmt"
	"time"

	"github.com/AndrewMommers/glint/server/blackjack"
)

const (
	gameCards     = "cards"
	gameBlackjack = "blackjack"

	bjMaxSeats = 5
	guestChips = 1000
	botChips   = 1000
)

// Table pacing (variables so tests can speed them up).
var (
	bjBetTime     = 15 * time.Second
	bjTurnTime    = 20 * time.Second
	bjResultsTime = 5 * time.Second
	bjDealerStep  = 800 * time.Millisecond
)

// bjTable is a Blackjack room's table state (touched only on the room goroutine).
type bjTable struct {
	shoe     *blackjack.Shoe
	round    *blackjack.Round
	order    []string       // seat ids dealt into the round; round seat i is order[i]
	phase    string         // betting, playing, dealer, results
	bets     map[string]int // bets placed this betting phase
	deadline time.Time      // betting / turn / results deadline
	turnKey  string         // "seat/hand" acting, to restart the turn timer on change
}

func gameName(kind string) string {
	if kind == gameBlackjack {
		return "Blackjack"
	}
	return "Glint Cards"
}

// seatChips is what a player brings to a Blackjack table: their account's
// balance (after any daily bonus), or a guest stack.
func (r *Room) seatChips(c *Client) int {
	if c.user == "" || r.hub.accounts == nil {
		return guestChips
	}
	chips, gift := r.hub.accounts.Chips(c.user)
	switch gift {
	case "start":
		c.send(map[string]any{"t": "notice", "kind": "info", "msg": fmt.Sprintf("Welcome! Here are %d chips to play with.", chips)})
	case "daily":
		c.send(map[string]any{"t": "notice", "kind": "info", "msg": fmt.Sprintf("Daily bonus: +%d chips", DailyBonus)})
	case "rescue":
		c.send(map[string]any{"t": "notice", "kind": "info", "msg": fmt.Sprintf("Out of chips? Here are %d to keep playing.", RescueChips)})
	}
	return chips
}

func (r *Room) bjStart() error {
	r.bj = &bjTable{shoe: blackjack.NewShoe(6, r.rng)}
	r.phase = "playing"
	r.round, r.match = 0, r.match+1
	r.bjBetting()
	return nil
}

// bjBetting opens a betting window, after clearing out players who left.
func (r *Room) bjBetting() {
	t := r.bj
	kept := r.seats[:0]
	for _, s := range r.seats {
		if s.away && time.Since(s.awayAt) > rejoinGrace {
			s.left = true // gone too long: free the seat
			r.sysChat(s.name + " left the table")
		}
		if !s.left {
			kept = append(kept, s)
		}
	}
	r.seats = kept
	r.migrateHost()
	if t.shoe.NeedsShuffle() {
		t.shoe.Reshuffle()
		r.sysChat("The dealer shuffles a fresh shoe")
	}
	for _, s := range r.seats {
		if s.bot() && !s.away && s.chips < r.settings.MinBet {
			s.chips = botChips
		}
	}
	t.round, t.order = nil, nil
	t.phase = "betting"
	t.bets = map[string]int{}
	t.deadline = time.Now().Add(bjBetTime)
	r.round++
	r.changed(nil, false)
}

// bjCanBet: seated, here, and can cover the minimum.
func (r *Room) bjCanBet(s *seat) bool {
	return !s.left && !s.away && s.chips >= r.settings.MinBet
}

func (r *Room) bjBet(s *seat, amount int) error {
	t := r.bj
	if t.phase != "betting" {
		return errors.New("bets are closed until the next hand")
	}
	if amount < r.settings.MinBet || amount > r.settings.MaxBet {
		return fmt.Errorf("bets are %d to %d chips", r.settings.MinBet, r.settings.MaxBet)
	}
	if amount > s.chips {
		return errors.New("you don't have enough chips")
	}
	t.bets[s.id] = amount
	// Deal as soon as everyone who can bet has.
	for _, o := range r.seats {
		if r.bjCanBet(o) && t.bets[o.id] == 0 {
			r.changed(nil, false)
			return nil
		}
	}
	r.bjDeal()
	return nil
}

func (r *Room) bjDeal() {
	t := r.bj
	if t.phase != "betting" {
		return
	}
	var bets []int
	t.order = nil
	for _, s := range r.seats {
		if b := t.bets[s.id]; b > 0 && !s.left {
			s.chips -= b
			bets = append(bets, b)
			t.order = append(t.order, s.id)
		}
	}
	if len(bets) == 0 { // nobody bet: keep the table open
		t.deadline = time.Now().Add(bjBetTime)
		r.changed(nil, false)
		return
	}
	t.round = blackjack.Deal(t.shoe, bets, blackjack.DefaultRules())
	t.phase = "playing"
	r.bjAfterMove()
}

// bjAfterMove moves the table along after any change to the round.
func (r *Room) bjAfterMove() {
	t := r.bj
	switch t.round.Phase {
	case blackjack.PhaseDealer:
		t.phase = "dealer"
	case blackjack.PhaseDone:
		r.bjSettle()
		return
	}
	r.changed(nil, false)
}

func (r *Room) bjSettle() {
	t := r.bj
	t.phase = "results"
	t.deadline = time.Now().Add(bjResultsTime)
	for i, id := range t.order {
		if j := r.seatIndex(id); j >= 0 {
			s := r.seats[j]
			s.chips += t.round.Payout(i)
			if s.user != "" && r.hub.accounts != nil {
				r.hub.accounts.SetChips(s.user, s.chips)
			}
		}
	}
	r.changed(nil, false)
}

// roundIndex is seat s's index in the current round, or -1.
func (t *bjTable) roundIndex(id string) int {
	for i, o := range t.order {
		if o == id {
			return i
		}
	}
	return -1
}

func (r *Room) bjAction(i int, m inMsg) error {
	t := r.bj
	s := r.seats[i]
	if m.T == "bet" {
		return r.bjBet(s, m.Amount)
	}
	if t.round == nil || t.phase != "playing" {
		return errors.New("wait for the next hand")
	}
	ri := t.roundIndex(s.id)
	if ri < 0 || t.round.Turn != ri {
		return blackjack.ErrNotYourTurn
	}
	var err error
	switch m.T {
	case "hit":
		err = t.round.Hit(ri)
	case "stand":
		err = t.round.Stand(ri)
	case "double", "split":
		h := t.round.Hand(ri)
		if h == nil || s.chips < h.Bet {
			return errors.New("you don't have enough chips for that")
		}
		stake := h.Bet
		if m.T == "double" {
			err = t.round.Double(ri)
		} else {
			err = t.round.Split(ri)
		}
		if err == nil {
			s.chips -= stake
		}
	default:
		return fmt.Errorf("unknown message %q", m.T)
	}
	if err != nil {
		return err
	}
	r.bjAfterMove()
	return nil
}

// bjBotMove plays the acting hand for a bot, or for a player who dropped
// out or left (they just stand).
func (r *Room) bjBotMove() {
	t := r.bj
	ri := t.round.Turn
	if ri < 0 {
		return
	}
	j := r.seatIndex(t.order[ri])
	if j < 0 || r.seats[j].left || r.seats[j].away {
		t.round.Stand(ri)
		r.bjAfterMove()
		return
	}
	s := r.seats[j]
	h := t.round.Hand(ri)
	switch blackjack.BotMove(t.round, ri, s.chips >= h.Bet, s.chips >= h.Bet) {
	case "double":
		s.chips -= h.Bet
		t.round.Double(ri)
	case "split":
		s.chips -= h.Bet
		t.round.Split(ri)
	case "hit":
		t.round.Hit(ri)
	default:
		t.round.Stand(ri)
	}
	r.bjAfterMove()
}

// bjSchedule arms the timers for the current table state (re-run on every change).
func (r *Room) bjSchedule() {
	t := r.bj
	if t == nil || r.phase != "playing" || r.humans() == 0 {
		return // nobody's connected: wait for someone to rejoin
	}
	switch t.phase {
	case "betting":
		for _, s := range r.seats {
			if s.bot() && !s.away && !s.left && t.bets[s.id] == 0 && s.chips >= r.settings.MinBet {
				s := s
				r.after(time.Duration(500+r.rng.Intn(1500))*time.Millisecond, func() {
					units := []int{1, 1, 2, 2, 3, 5}[r.rng.Intn(6)]
					amount := min(r.settings.MinBet*units, s.chips, r.settings.MaxBet)
					r.bjBet(s, amount)
				})
			}
		}
		r.after(time.Until(t.deadline), r.bjDeal)
	case "playing":
		ri := t.round.Turn
		if ri < 0 {
			return
		}
		j := r.seatIndex(t.order[ri])
		if j < 0 || r.seats[j].bot() || r.seats[j].left {
			r.after(time.Duration(700+r.rng.Intn(700))*time.Millisecond, r.bjBotMove)
			return
		}
		r.after(time.Until(t.deadline), func() { // turn timer ran out: stand
			if t.round.Turn == ri {
				t.round.Stand(ri)
				r.bjAfterMove()
			}
		})
	case "dealer":
		r.after(bjDealerStep, func() {
			if t.round.DealerStep() {
				r.bjSettle()
			} else {
				r.changed(nil, false)
			}
		})
	case "results":
		r.after(time.Until(t.deadline), func() {
			if t.phase == "results" {
				r.bjBetting()
			}
		})
	}
}

// bjTurnTimer restarts the turn clock whenever a different hand is up.
func (r *Room) bjTurnTimer() {
	t := r.bj
	if t == nil || t.phase != "playing" || t.round == nil || t.round.Turn < 0 {
		t.turnKey = ""
		return
	}
	ri := t.round.Turn
	key := fmt.Sprintf("%s/%d", t.order[ri], t.round.Seats[ri].Active)
	if key != t.turnKey {
		t.turnKey = key
		t.deadline = time.Now().Add(bjTurnTime)
	}
}

// ---- state ----

type bjCardJ struct {
	Rank string `json:"rank"` // "" for a face-down card
	Suit string `json:"suit"`
}

type bjHandJ struct {
	Cards   []bjCardJ `json:"cards"`
	Total   int       `json:"total"`
	Soft    bool      `json:"soft,omitempty"`
	Bet     int       `json:"bet"`
	Doubled bool      `json:"doubled,omitempty"`
	Result  string    `json:"result,omitempty"`
	Payout  int       `json:"payout,omitempty"`
	Active  bool      `json:"active,omitempty"`
}

type bjSeatJ struct {
	ID    string    `json:"id"`
	Chips int       `json:"chips"`
	Bet   int       `json:"bet,omitempty"` // placed this betting phase
	Hands []bjHandJ `json:"hands"`
}

type bjStateJ struct {
	Phase       string    `json:"phase"` // betting, playing, dealer, results
	Dealer      []bjCardJ `json:"dealer"`
	DealerTotal int       `json:"dealerTotal"` // of the visible cards
	Turn        string    `json:"turn,omitempty"`
	TimeLeft    float64   `json:"timeLeft"`
	MinBet      int       `json:"minBet"`
	MaxBet      int       `json:"maxBet"`
	Seats       []bjSeatJ `json:"seats"`
	CanDouble   bool      `json:"canDouble,omitempty"`
	CanSplit    bool      `json:"canSplit,omitempty"`
}

func bjCard(c blackjack.Card) bjCardJ { return bjCardJ{Rank: c.RankName(), Suit: c.Suit.String()} }

func (r *Room) bjState(viewer int) *bjStateJ {
	t := r.bj
	st := &bjStateJ{Phase: t.phase, MinBet: r.settings.MinBet, MaxBet: r.settings.MaxBet,
		Dealer: []bjCardJ{}, Seats: []bjSeatJ{}}
	if !t.deadline.IsZero() && t.phase != "dealer" {
		st.TimeLeft = max(time.Until(t.deadline).Seconds(), 0)
	}
	if rd := t.round; rd != nil {
		visible := rd.Dealer
		if rd.HoleHidden() {
			visible = rd.Dealer[:1]
		}
		for _, c := range visible {
			st.Dealer = append(st.Dealer, bjCard(c))
		}
		if rd.HoleHidden() {
			st.Dealer = append(st.Dealer, bjCardJ{})
		}
		st.DealerTotal, _ = blackjack.Value(visible)
		if rd.Turn >= 0 {
			st.Turn = t.order[rd.Turn]
		}
	}
	for _, s := range r.seats {
		sj := bjSeatJ{ID: s.id, Chips: s.chips, Bet: t.bets[s.id], Hands: []bjHandJ{}}
		if rd := t.round; rd != nil {
			if ri := t.roundIndex(s.id); ri >= 0 {
				rs := rd.Seats[ri]
				for hi, h := range rs.Hands {
					hj := bjHandJ{Bet: h.Bet, Doubled: h.Doubled, Result: h.Result, Payout: h.Payout,
						Active: rd.Turn == ri && rs.Active == hi}
					for _, c := range h.Cards {
						hj.Cards = append(hj.Cards, bjCard(c))
					}
					hj.Total, hj.Soft = blackjack.Value(h.Cards)
					sj.Hands = append(sj.Hands, hj)
				}
			}
		}
		st.Seats = append(st.Seats, sj)
	}
	if viewer >= 0 && t.round != nil && t.phase == "playing" {
		if ri := t.roundIndex(r.seats[viewer].id); ri >= 0 && t.round.Turn == ri {
			h := t.round.Hand(ri)
			canPay := h != nil && r.seats[viewer].chips >= h.Bet
			st.CanDouble = canPay && t.round.CanDouble(ri)
			st.CanSplit = canPay && t.round.CanSplit(ri)
		}
	}
	return st
}
