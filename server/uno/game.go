package uno

import (
	"errors"
	"math/rand"
)

var (
	ErrGameOver    = errors.New("the round is over")
	ErrNotYourTurn = errors.New("it's not your turn")
	ErrNoSuchCard  = errors.New("you don't have that card")
	ErrIllegal     = errors.New("that card can't be played now")
	ErrNeedColor   = errors.New("choose a color for the wild card")
	ErrAlreadyDrew = errors.New("you already drew - play the drawn card or pass")
	ErrCantPass    = errors.New("you can't pass right now")
	ErrMustPlay    = errors.New("force play is on - you must play the drawn card")
	ErrNothingToDo = errors.New("nothing to declare")
	ErrNoCatch     = errors.New("nobody to catch")
	ErrBadTarget   = errors.New("pick another player to swap hands with")
)

// Rules are the optional house rules for a round.
type Rules struct {
	HandSize    int  `json:"handSize"`    // starting cards (default 7)
	Stacking    bool `json:"stacking"`    // +2 on +2, +4 on +2/+4; the stack is drawn by whoever can't add to it
	DrawToMatch bool `json:"drawToMatch"` // keep drawing until a playable card comes up
	ForcePlay   bool `json:"forcePlay"`   // a playable drawn card must be played
	SevenO      bool `json:"sevenO"`      // 7 swaps hands with a chosen player, 0 rotates all hands
	JumpIn      bool `json:"jumpIn"`      // an identical card may be played out of turn
}

func DefaultRules() Rules { return Rules{HandSize: 7} }

// Normalize clamps values into a sane range.
func (r Rules) Normalize() Rules {
	if r.HandSize < 3 || r.HandSize > 15 {
		r.HandSize = 7
	}
	return r
}

type Player struct {
	Hand        []Card
	UnoDeclared bool // called GLINT while holding two cards, before playing
	Vulnerable  bool // down to one card without calling GLINT - can be caught
}

// Event describes something that happened, for clients to animate.
type Event struct {
	Kind   string // play, jumpin, draw, pass, skip, reverse, draw2, wild4, stack, penalty, swap, rotate, uno, catch, win
	Player int
	Target int
	Card   *Card
	Count  int
	Color  Color
}

type Game struct {
	Rules       Rules
	Players     []*Player
	DrawPile    []Card
	Discard     []Card
	Color       Color // active color (differs from top card after a wild)
	Turn        int
	Dir         int   // +1 clockwise, -1 counter-clockwise
	Drawn       *Card // card drawn this turn that is playable; player must play it or pass
	PendingDraw int   // stacked +2/+4 cards waiting to be drawn (stacking rule)
	Winner      int   // -1 while the round is running
	rng         *rand.Rand
}

// New deals a fresh round for n players; first takes the first turn.
func New(n, first int, rules Rules, rng *rand.Rand) *Game {
	rules = rules.Normalize()
	g := &Game{Rules: rules, Dir: 1, Winner: -1, rng: rng, Turn: first}
	g.DrawPile = NewDeck(rng)
	for i := 0; i < n; i++ {
		g.Players = append(g.Players, &Player{})
	}
	for k := 0; k < rules.HandSize; k++ {
		for _, p := range g.Players {
			if c, ok := g.draw(); ok {
				p.Hand = append(p.Hand, c)
			}
		}
	}
	// Start on a number card; anything else goes to the bottom of the pile.
	for {
		c, _ := g.draw()
		if c.IsNumber() {
			g.Discard = append(g.Discard, c)
			g.Color = c.Color
			break
		}
		g.DrawPile = append([]Card{c}, g.DrawPile...)
	}
	return g
}

func (g *Game) Top() Card { return g.Discard[len(g.Discard)-1] }

func (g *Game) CanPlay(c Card) bool {
	if g.PendingDraw > 0 {
		return c.Value == WildDrawFour || (c.Value == DrawTwo && g.Top().Value == DrawTwo)
	}
	return c.IsWild() || c.Color == g.Color || c.Value == g.Top().Value
}

// CanJumpIn reports whether c is an exact match for the top card that may be
// played out of turn.
func (g *Game) CanJumpIn(pi int, c Card) bool {
	top := g.Top()
	return g.Rules.JumpIn && g.Winner < 0 && pi != g.Turn && g.Drawn == nil &&
		g.PendingDraw == 0 && !c.IsWild() && c.Color == top.Color &&
		c.Value == top.Value && g.Color == top.Color
}

// PlayableCards lists the cards player pi may legally play right now,
// including jump-ins when it isn't their turn.
func (g *Game) PlayableCards(pi int) []Card {
	if g.Winner >= 0 {
		return nil
	}
	var out []Card
	if pi != g.Turn {
		for _, c := range g.Players[pi].Hand {
			if g.CanJumpIn(pi, c) {
				out = append(out, c)
			}
		}
		return out
	}
	if g.Drawn != nil {
		if g.CanPlay(*g.Drawn) {
			return []Card{*g.Drawn}
		}
		return nil
	}
	for _, c := range g.Players[pi].Hand {
		if g.CanPlay(c) {
			out = append(out, c)
		}
	}
	return out
}

func (g *Game) Next(step int) int { return g.seat(g.Turn, step) }

func (g *Game) seat(from, step int) int {
	n := len(g.Players)
	return ((from+g.Dir*step)%n + n) % n
}

func (g *Game) draw() (Card, bool) {
	if len(g.DrawPile) == 0 {
		if len(g.Discard) <= 1 {
			return Card{}, false
		}
		top := g.Discard[len(g.Discard)-1]
		g.DrawPile = append([]Card(nil), g.Discard[:len(g.Discard)-1]...)
		g.Discard = []Card{top}
		g.rng.Shuffle(len(g.DrawPile), func(i, j int) {
			g.DrawPile[i], g.DrawPile[j] = g.DrawPile[j], g.DrawPile[i]
		})
	}
	c := g.DrawPile[len(g.DrawPile)-1]
	g.DrawPile = g.DrawPile[:len(g.DrawPile)-1]
	return c, true
}

func (g *Game) give(pi, n int) int {
	got := 0
	for ; got < n; got++ {
		c, ok := g.draw()
		if !ok {
			break
		}
		g.Players[pi].Hand = append(g.Players[pi].Hand, c)
	}
	return got
}

// The window to catch a missing GLINT call closes as soon as anyone acts.
func (g *Game) closeCatchWindow() {
	for _, p := range g.Players {
		p.Vulnerable = false
	}
}

func (g *Game) checkTurn(pi int) error {
	if g.Winner >= 0 {
		return ErrGameOver
	}
	if pi != g.Turn {
		return ErrNotYourTurn
	}
	return nil
}

// Play puts a card from player pi's hand on the discard pile.
// chosen is the color for wild cards, target the swap partner for a 7 under
// Seven-O (-1 picks automatically), and uno declares GLINT along with the play.
func (g *Game) Play(pi, cardID int, chosen Color, target int, uno bool) ([]Event, error) {
	if g.Winner >= 0 {
		return nil, ErrGameOver
	}
	p := g.Players[pi]
	idx := -1
	for i, c := range p.Hand {
		if c.ID == cardID {
			idx = i
			break
		}
	}
	if idx < 0 {
		return nil, ErrNoSuchCard
	}
	card := p.Hand[idx]

	kind := "play"
	if pi != g.Turn {
		if !g.CanJumpIn(pi, card) {
			return nil, ErrNotYourTurn
		}
		kind = "jumpin"
	} else {
		if g.Drawn != nil && g.Drawn.ID != cardID {
			return nil, ErrAlreadyDrew
		}
		if !g.CanPlay(card) {
			return nil, ErrIllegal
		}
	}
	if card.IsWild() && (chosen < Red || chosen > Blue) {
		return nil, ErrNeedColor
	}
	sevenSwap := g.Rules.SevenO && card.Value == 7 && len(g.Players) > 1
	if sevenSwap && target >= 0 && (target == pi || target >= len(g.Players)) {
		return nil, ErrBadTarget
	}

	g.closeCatchWindow()
	g.Turn = pi
	p.Hand = append(p.Hand[:idx], p.Hand[idx+1:]...)
	g.Discard = append(g.Discard, card)
	g.Drawn = nil
	if card.IsWild() {
		g.Color = chosen
	} else {
		g.Color = card.Color
	}
	events := []Event{{Kind: kind, Player: pi, Target: -1, Card: &card, Color: g.Color}}

	if len(p.Hand) == 1 {
		if uno || p.UnoDeclared {
			events = append(events, Event{Kind: "uno", Player: pi, Target: -1})
		} else {
			p.Vulnerable = true
		}
	}
	p.UnoDeclared = false
	won := len(p.Hand) == 0

	switch card.Value {
	case Skip:
		events = append(events, Event{Kind: "skip", Player: pi, Target: g.Next(1)})
		g.Turn = g.Next(2)
	case Reverse:
		events = append(events, Event{Kind: "reverse", Player: pi, Target: -1})
		if len(g.Players) == 2 {
			g.Turn = g.Next(2) // acts like a skip
		} else {
			g.Dir = -g.Dir
			g.Turn = g.Next(1)
		}
	case DrawTwo, WildDrawFour:
		n, k := 2, "draw2"
		if card.Value == WildDrawFour {
			n, k = 4, "wild4"
		}
		if g.Rules.Stacking && !won {
			g.PendingDraw += n
			g.Turn = g.Next(1)
			events = append(events, Event{Kind: "stack", Player: pi, Target: g.Turn, Count: g.PendingDraw})
		} else {
			n += g.PendingDraw
			g.PendingDraw = 0
			t := g.Next(1)
			got := g.give(t, n)
			events = append(events, Event{Kind: k, Player: pi, Target: t, Count: got})
			g.Turn = g.Next(2)
		}
	case 7:
		if sevenSwap && !won {
			if target < 0 {
				target = g.fewestCards(pi)
			}
			p.Hand, g.Players[target].Hand = g.Players[target].Hand, p.Hand
			g.closeCatchWindow()
			events = append(events, Event{Kind: "swap", Player: pi, Target: target})
		}
		g.Turn = g.Next(1)
	case 0:
		if g.Rules.SevenO && !won {
			g.rotateHands()
			g.closeCatchWindow()
			events = append(events, Event{Kind: "rotate", Player: pi, Target: -1})
		}
		g.Turn = g.Next(1)
	default:
		g.Turn = g.Next(1)
	}

	if won {
		g.Winner = pi
		g.PendingDraw = 0
		p.Vulnerable = false
		events = append(events, Event{Kind: "win", Player: pi, Target: -1})
	}
	return events, nil
}

func (g *Game) fewestCards(except int) int {
	best := -1
	for i, p := range g.Players {
		if i != except && (best < 0 || len(p.Hand) < len(g.Players[best].Hand)) {
			best = i
		}
	}
	return best
}

// rotateHands passes every hand to the next player in the direction of play.
func (g *Game) rotateHands() {
	n := len(g.Players)
	hands := make([][]Card, n)
	for i, p := range g.Players {
		hands[g.seat(i, 1)] = p.Hand
	}
	for i, p := range g.Players {
		p.Hand = hands[i]
	}
}

// DrawCard draws for the current player. With a stacked penalty pending the
// player takes the whole stack and loses the turn. Otherwise one card is drawn
// (or, with DrawToMatch, cards until one is playable); if it's playable the
// turn stays with the player, who must then Play it or Pass.
func (g *Game) DrawCard(pi int) ([]Event, error) {
	if err := g.checkTurn(pi); err != nil {
		return nil, err
	}
	if g.Drawn != nil {
		return nil, ErrAlreadyDrew
	}
	g.closeCatchWindow()

	if g.PendingDraw > 0 {
		got := g.give(pi, g.PendingDraw)
		g.PendingDraw = 0
		g.Turn = g.Next(1)
		return []Event{{Kind: "penalty", Player: pi, Target: -1, Count: got}}, nil
	}

	count := 0
	var last Card
	for {
		c, ok := g.draw()
		if !ok {
			break
		}
		count++
		last = c
		g.Players[pi].Hand = append(g.Players[pi].Hand, c)
		if g.CanPlay(c) || !g.Rules.DrawToMatch {
			break
		}
	}
	if count == 0 { // no cards left anywhere
		g.Turn = g.Next(1)
		return []Event{{Kind: "pass", Player: pi, Target: -1}}, nil
	}
	if g.CanPlay(last) {
		g.Drawn = &last
	} else {
		g.Turn = g.Next(1)
	}
	return []Event{{Kind: "draw", Player: pi, Target: -1, Count: count, Card: &last}}, nil
}

// Pass ends the turn after drawing a playable card the player wants to keep.
func (g *Game) Pass(pi int) ([]Event, error) {
	if err := g.checkTurn(pi); err != nil {
		return nil, err
	}
	if g.Drawn == nil {
		return nil, ErrCantPass
	}
	if g.Rules.ForcePlay {
		return nil, ErrMustPlay
	}
	g.Drawn = nil
	g.Turn = g.Next(1)
	return []Event{{Kind: "pass", Player: pi, Target: -1}}, nil
}

// DeclareUno either pre-arms the GLINT call (two cards, your turn) or saves a player who
// already went down to one card without calling it.
func (g *Game) DeclareUno(pi int) ([]Event, error) {
	if g.Winner >= 0 {
		return nil, ErrGameOver
	}
	p := g.Players[pi]
	switch {
	case p.Vulnerable && len(p.Hand) == 1:
		p.Vulnerable = false
		return []Event{{Kind: "uno", Player: pi, Target: -1}}, nil
	case len(p.Hand) == 2:
		p.UnoDeclared = true
		return nil, nil
	}
	return nil, ErrNothingToDo
}

// Catch penalises any opponent of catcher who forgot to call GLINT.
func (g *Game) Catch(catcher int) ([]Event, error) {
	if g.Winner >= 0 {
		return nil, ErrGameOver
	}
	for i, p := range g.Players {
		if i != catcher && p.Vulnerable {
			p.Vulnerable = false
			got := g.give(i, 2)
			return []Event{{Kind: "catch", Player: catcher, Target: i, Count: got}}, nil
		}
	}
	return nil, ErrNoCatch
}

// CatchableBy reports whether catcher currently has someone to catch.
func (g *Game) CatchableBy(catcher int) bool {
	for i, p := range g.Players {
		if i != catcher && p.Vulnerable {
			return true
		}
	}
	return false
}

// Timeout performs the default action for an idle player: draw, then pass
// (or, under force play, play the drawn card).
func (g *Game) Timeout(pi int) ([]Event, error) {
	var events []Event
	if g.Drawn == nil {
		ev, err := g.DrawCard(pi)
		if err != nil {
			return nil, err
		}
		events = append(events, ev...)
	}
	if g.Drawn != nil && g.Turn == pi {
		var ev []Event
		var err error
		if g.Rules.ForcePlay {
			ev, err = g.Play(pi, g.Drawn.ID, BestColor(g.Players[pi].Hand, g.Drawn.ID), -1, true)
		} else {
			ev, err = g.Pass(pi)
		}
		if err != nil {
			return nil, err
		}
		events = append(events, ev...)
	}
	return events, nil
}

// RoundPoints is what the winner earns: the value of every card left in
// the other players' hands.
func (g *Game) RoundPoints() int {
	total := 0
	for i, p := range g.Players {
		if i == g.Winner {
			continue
		}
		for _, c := range p.Hand {
			total += c.Points()
		}
	}
	return total
}
