package uno

import (
	"math/rand"
	"time"
)

type Difficulty int

const (
	Easy Difficulty = iota
	Normal
	Hard
)

func ParseDifficulty(s string) Difficulty {
	switch s {
	case "easy":
		return Easy
	case "hard":
		return Hard
	}
	return Normal
}

func (d Difficulty) String() string {
	return [...]string{"easy", "normal", "hard"}[d]
}

// Move is a bot's decision for its turn.
type Move struct {
	Kind   string // play, draw, pass
	CardID int
	Color  Color
	Target int
	Uno    bool
}

// BestColor returns the color the hand holds most of, ignoring card skip.
func BestColor(hand []Card, skip int) Color {
	var counts [4]int
	for _, c := range hand {
		if c.ID != skip && !c.IsWild() {
			counts[c.Color]++
		}
	}
	best := Red
	for c := Red; c <= Blue; c++ {
		if counts[c] > counts[best] {
			best = c
		}
	}
	return best
}

// BotMove picks a move for player pi.
func BotMove(g *Game, pi int, d Difficulty, rng *rand.Rand) Move {
	hand := g.Players[pi].Hand
	options := g.PlayableCards(pi)
	if len(options) == 0 {
		if g.Drawn != nil {
			return Move{Kind: "pass"}
		}
		return Move{Kind: "draw"}
	}

	var pick Card
	if d == Easy {
		pick = options[rng.Intn(len(options))]
	} else {
		nextCards := len(g.Players[g.Next(1)].Hand)
		bestScore := -1 << 30
		for _, c := range options {
			s := scoreCard(c, hand, nextCards)
			if d == Normal {
				s += rng.Intn(12)
			}
			if s > bestScore {
				bestScore, pick = s, c
			}
		}
	}

	m := Move{Kind: "play", CardID: pick.ID, Target: -1}
	if pick.IsWild() {
		if d == Easy {
			m.Color = Color(rng.Intn(4))
		} else {
			m.Color = BestColor(hand, pick.ID)
		}
	}
	if g.Rules.SevenO && pick.Value == 7 && d != Easy {
		m.Target = g.fewestCards(pi)
	}
	if len(hand) == 2 {
		chance := [...]float64{0.6, 0.85, 1}[d]
		m.Uno = rng.Float64() < chance
	}
	return m
}

func scoreCard(c Card, hand []Card, nextCards int) int {
	s := 0
	switch {
	case c.Value == WildDrawFour:
		s = 0
	case c.Value == WildCard:
		s = 2
	case c.IsNumber():
		s = 10 + int(c.Value) // dump high-value cards
	default:
		s = 15
	}
	if nextCards <= 2 {
		switch c.Value {
		case DrawTwo, WildDrawFour:
			s += 40
		case Skip, Reverse:
			s += 30
		}
	}
	if !c.IsWild() {
		for _, h := range hand {
			if h.ID != c.ID && h.Color == c.Color {
				s += 3 // keep playing into our strongest color
			}
		}
	}
	return s
}

// BotThinkDelay is how long a bot "thinks" before acting.
func BotThinkDelay(rng *rand.Rand) time.Duration {
	return 700*time.Millisecond + time.Duration(rng.Intn(900))*time.Millisecond
}

// BotReaction returns whether a bot notices a catch / jump-in chance and how
// long it takes to react.
func BotReaction(d Difficulty, rng *rand.Rand) (bool, time.Duration) {
	chance := [...]float64{0.35, 0.65, 0.95}[d]
	base := [...]int{2200, 1400, 700}[d]
	return rng.Float64() < chance, time.Duration(base+rng.Intn(900)) * time.Millisecond
}
