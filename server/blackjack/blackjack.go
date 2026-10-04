// Package blackjack is the rules engine for Glint's Blackjack: a shoe, hands,
// player actions, the dealer and payouts, plus a basic-strategy bot. It knows
// nothing about networking or chips accounts; the server room does that.
package blackjack

import (
	"errors"
	"math/rand"
)

// ---- cards ----

type Suit int

const (
	Spades Suit = iota
	Hearts
	Diamonds
	Clubs
)

var suitNames = [...]string{"S", "H", "D", "C"}
var rankNames = [...]string{"", "A", "2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K"}

func (s Suit) String() string { return suitNames[s] }

// Card is a playing card; Rank runs 1 (ace) to 13 (king).
type Card struct {
	Rank int
	Suit Suit
}

func (c Card) RankName() string { return rankNames[c.Rank] }

// points is the card's blackjack value, aces counting 1.
func (c Card) points() int {
	if c.Rank >= 10 {
		return 10
	}
	return c.Rank
}

// ---- shoe ----

// Shoe is several shuffled decks; it reshuffles once it's mostly dealt.
type Shoe struct {
	decks int
	cards []Card
	rng   *rand.Rand
}

func NewShoe(decks int, rng *rand.Rand) *Shoe {
	s := &Shoe{decks: decks, rng: rng}
	s.shuffle()
	return s
}

func (s *Shoe) shuffle() {
	s.cards = s.cards[:0]
	for d := 0; d < s.decks; d++ {
		for suit := Spades; suit <= Clubs; suit++ {
			for rank := 1; rank <= 13; rank++ {
				s.cards = append(s.cards, Card{rank, suit})
			}
		}
	}
	s.rng.Shuffle(len(s.cards), func(i, j int) { s.cards[i], s.cards[j] = s.cards[j], s.cards[i] })
}

// Left is how many cards remain before the next shuffle.
func (s *Shoe) Left() int { return len(s.cards) }

// NeedsShuffle reports whether the shoe is past its cut card (75% dealt).
func (s *Shoe) NeedsShuffle() bool { return len(s.cards) < s.decks*52/4 }

// Reshuffle starts a fresh shoe (between rounds).
func (s *Shoe) Reshuffle() { s.shuffle() }

func (s *Shoe) Draw() Card {
	if len(s.cards) == 0 {
		s.shuffle() // never runs dry mid-round
	}
	c := s.cards[len(s.cards)-1]
	s.cards = s.cards[:len(s.cards)-1]
	return c
}

// ---- hands ----

// Value is a hand's best total and whether an ace is counting as 11.
func Value(cards []Card) (total int, soft bool) {
	aces := 0
	for _, c := range cards {
		total += c.points()
		if c.Rank == 1 {
			aces++
		}
	}
	if aces > 0 && total+10 <= 21 {
		return total + 10, true
	}
	return total, false
}

type Hand struct {
	Cards   []Card
	Bet     int
	Doubled bool
	Split   bool // came from a split (so 21 in two cards isn't a blackjack)
	Done    bool
	Result  string // set when settled: blackjack, win, push, lose, bust
	Payout  int    // chips paid back, stake included
}

func (h *Hand) Total() int        { t, _ := Value(h.Cards); return t }
func (h *Hand) Busted() bool      { return h.Total() > 21 }
func (h *Hand) IsBlackjack() bool { return len(h.Cards) == 2 && !h.Split && h.Total() == 21 }

// ---- rounds ----

type Rules struct {
	MaxHands         int  // most hands one player can split into
	DealerHitsSoft17 bool // false: the dealer stands on all 17s
}

func DefaultRules() Rules { return Rules{MaxHands: 4} }

// Seat is one player's part of a round.
type Seat struct {
	Hands  []*Hand
	Active int  // index of the hand being played
	In     bool // placed a bet this round
}

// Phases of a round.
const (
	PhasePlaying = "playing" // players act in seat order
	PhaseDealer  = "dealer"  // the dealer draws
	PhaseDone    = "done"    // settled
)

type Round struct {
	Seats  []*Seat
	Dealer []Card
	Turn   int // seat acting, -1 when no player is
	Phase  string
	Rules  Rules
	shoe   *Shoe
}

var (
	ErrNotYourTurn = errors.New("it's not your turn")
	ErrIllegal     = errors.New("you can't do that now")
)

// Deal starts a round: bets[i] > 0 means seat i plays. Two cards each, two
// for the dealer (the second face down). If the dealer shows an ace or a
// ten and has blackjack, the round settles at once.
func Deal(shoe *Shoe, bets []int, rules Rules) *Round {
	r := &Round{Turn: -1, Phase: PhasePlaying, Rules: rules, shoe: shoe}
	for _, b := range bets {
		s := &Seat{In: b > 0}
		if s.In {
			s.Hands = []*Hand{{Bet: b}}
		}
		r.Seats = append(r.Seats, s)
	}
	for round := 0; round < 2; round++ {
		for _, s := range r.Seats {
			if s.In {
				s.Hands[0].Cards = append(s.Hands[0].Cards, shoe.Draw())
			}
		}
		r.Dealer = append(r.Dealer, shoe.Draw())
	}
	for _, s := range r.Seats {
		if s.In && s.Hands[0].IsBlackjack() {
			s.Hands[0].Done = true
		}
	}
	if up := r.Dealer[0]; up.Rank == 1 || up.points() == 10 {
		if t, _ := Value(r.Dealer); t == 21 {
			r.settle()
			return r
		}
	}
	r.Turn = -1
	r.advance()
	return r
}

// Upcard is the dealer's face-up card.
func (r *Round) Upcard() Card { return r.Dealer[0] }

// HoleHidden reports whether the dealer's second card is still face down.
func (r *Round) HoleHidden() bool { return r.Phase == PhasePlaying }

// Hand returns the hand seat i is playing now, or nil.
func (r *Round) Hand(i int) *Hand {
	if i < 0 || i >= len(r.Seats) || !r.Seats[i].In || r.Seats[i].Active >= len(r.Seats[i].Hands) {
		return nil
	}
	return r.Seats[i].Hands[r.Seats[i].Active]
}

// CanDouble: first two cards of a hand (after a split too).
func (r *Round) CanDouble(i int) bool {
	h := r.Hand(i)
	return r.Phase == PhasePlaying && r.Turn == i && h != nil && len(h.Cards) == 2
}

// CanSplit: a pair (by rank) and room for another hand.
func (r *Round) CanSplit(i int) bool {
	h := r.Hand(i)
	return r.Phase == PhasePlaying && r.Turn == i && h != nil && len(h.Cards) == 2 &&
		h.Cards[0].points() == h.Cards[1].points() && len(r.Seats[i].Hands) < r.Rules.MaxHands
}

func (r *Round) check(i int) (*Hand, error) {
	if r.Phase != PhasePlaying || r.Turn != i {
		return nil, ErrNotYourTurn
	}
	return r.Hand(i), nil
}

func (r *Round) Hit(i int) error {
	h, err := r.check(i)
	if err != nil {
		return err
	}
	h.Cards = append(h.Cards, r.shoe.Draw())
	if h.Total() >= 21 {
		h.Done = true
		r.advance()
	}
	return nil
}

func (r *Round) Stand(i int) error {
	h, err := r.check(i)
	if err != nil {
		return err
	}
	h.Done = true
	r.advance()
	return nil
}

// Double doubles the bet, takes exactly one card and ends the hand. The
// caller has already taken the extra stake (the hand's original bet).
func (r *Round) Double(i int) error {
	if !r.CanDouble(i) {
		return ErrIllegal
	}
	h := r.Hand(i)
	h.Bet *= 2
	h.Doubled = true
	h.Cards = append(h.Cards, r.shoe.Draw())
	h.Done = true
	r.advance()
	return nil
}

// Split turns a pair into two hands with the same bet each. The caller has
// already taken the extra stake. Split aces get one card each.
func (r *Round) Split(i int) error {
	if !r.CanSplit(i) {
		return ErrIllegal
	}
	s := r.Seats[i]
	h := s.Hands[s.Active]
	second := &Hand{Cards: []Card{h.Cards[1]}, Bet: h.Bet, Split: true}
	h.Cards = []Card{h.Cards[0], r.shoe.Draw()}
	h.Split = true
	second.Cards = append(second.Cards, r.shoe.Draw())
	s.Hands = append(s.Hands[:s.Active+1], append([]*Hand{second}, s.Hands[s.Active+1:]...)...)
	if h.Cards[0].Rank == 1 {
		h.Done, second.Done = true, true
	}
	for _, x := range []*Hand{h, second} {
		if x.Total() == 21 {
			x.Done = true
		}
	}
	r.advance()
	return nil
}

// advance moves to the next unfinished hand, then to the dealer.
func (r *Round) advance() {
	start := r.Turn
	if start < 0 {
		start = 0
	}
	for i := start; i < len(r.Seats); i++ {
		s := r.Seats[i]
		if !s.In {
			continue
		}
		for s.Active < len(s.Hands) && s.Hands[s.Active].Done {
			s.Active++
		}
		if s.Active < len(s.Hands) {
			r.Turn = i
			return
		}
	}
	r.Turn = -1
	r.Phase = PhaseDealer
	// Nobody left with a live hand: the dealer just turns the hole card over.
	live := false
	for _, s := range r.Seats {
		for _, h := range s.Hands {
			if !h.Busted() && !h.IsBlackjack() {
				live = true
			}
		}
	}
	if !live {
		r.settle()
	}
}

// DealerStep draws one dealer card if the dealer must hit; when the dealer
// is finished it settles the round. It returns true once settled.
func (r *Round) DealerStep() bool {
	if r.Phase != PhaseDealer {
		return r.Phase == PhaseDone
	}
	t, soft := Value(r.Dealer)
	if t < 17 || (t == 17 && soft && r.Rules.DealerHitsSoft17) {
		r.Dealer = append(r.Dealer, r.shoe.Draw())
		return false
	}
	r.settle()
	return true
}

func (r *Round) settle() {
	r.Phase = PhaseDone
	r.Turn = -1
	d, _ := Value(r.Dealer)
	dealerBJ := len(r.Dealer) == 2 && d == 21
	for _, s := range r.Seats {
		for _, h := range s.Hands {
			switch t := h.Total(); {
			case h.IsBlackjack() && dealerBJ:
				h.Result, h.Payout = "push", h.Bet
			case h.IsBlackjack():
				h.Result, h.Payout = "blackjack", h.Bet+h.Bet*3/2
			case t > 21:
				h.Result, h.Payout = "bust", 0
			case dealerBJ:
				h.Result, h.Payout = "lose", 0
			case d > 21 || t > d:
				h.Result, h.Payout = "win", h.Bet*2
			case t == d:
				h.Result, h.Payout = "push", h.Bet
			default:
				h.Result, h.Payout = "lose", 0
			}
			h.Done = true
		}
	}
}

// Payout is everything seat i gets back this round (stakes included).
func (r *Round) Payout(i int) int {
	n := 0
	for _, h := range r.Seats[i].Hands {
		n += h.Payout
	}
	return n
}

// Staked is everything seat i has put in this round.
func (r *Round) Staked(i int) int {
	n := 0
	for _, h := range r.Seats[i].Hands {
		n += h.Bet
	}
	return n
}

// ---- bots ----

// BotMove is basic strategy (multi-deck, dealer stands on soft 17). It
// returns hit, stand, double or split; canDouble/canSplit include chips.
func BotMove(r *Round, i int, canDouble, canSplit bool) string {
	h := r.Hand(i)
	up := r.Upcard().points()
	if up == 1 {
		up = 11
	}
	if canSplit && r.CanSplit(i) {
		switch p := h.Cards[0].points(); {
		case p == 1 || p == 8:
			return "split"
		case p == 9 && up != 7 && up != 10 && up != 11:
			return "split"
		case (p == 2 || p == 3 || p == 7) && up <= 7:
			return "split"
		case p == 6 && up <= 6:
			return "split"
		case p == 4 && (up == 5 || up == 6):
			return "split"
		}
	}
	t, soft := Value(h.Cards)
	double := canDouble && r.CanDouble(i)
	if soft {
		switch {
		case t >= 19:
			return "stand"
		case t == 18:
			if double && up >= 3 && up <= 6 {
				return "double"
			}
			if up >= 9 {
				return "hit"
			}
			return "stand"
		case double && ((t >= 15 && up >= 4 && up <= 6) || (t >= 13 && up >= 5 && up <= 6)):
			return "double"
		default:
			return "hit"
		}
	}
	switch {
	case t >= 17:
		return "stand"
	case t >= 13 && up <= 6:
		return "stand"
	case t == 12 && up >= 4 && up <= 6:
		return "stand"
	case t == 11 && double:
		return "double"
	case t == 10 && double && up <= 9:
		return "double"
	case t == 9 && double && up >= 3 && up <= 6:
		return "double"
	}
	return "hit"
}
