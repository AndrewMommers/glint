// Package uno implements the rules of UNO, independent of networking.
package uno

import (
	"fmt"
	"math/rand"
)

type Color int8

const (
	Red Color = iota
	Yellow
	Green
	Blue
	Wild // colorless (wild cards before a color is chosen)
)

var colorNames = [...]string{"red", "yellow", "green", "blue", "wild"}

func (c Color) String() string {
	if c < 0 || int(c) >= len(colorNames) {
		return "?"
	}
	return colorNames[c]
}

// ParseColor parses one of the four playable colors.
func ParseColor(s string) (Color, bool) {
	for i, n := range colorNames[:4] {
		if n == s {
			return Color(i), true
		}
	}
	return Wild, false
}

type Value int8

const (
	Skip Value = iota + 10
	Reverse
	DrawTwo
	WildCard
	WildDrawFour
)

func (v Value) String() string {
	switch v {
	case Skip:
		return "skip"
	case Reverse:
		return "reverse"
	case DrawTwo:
		return "draw2"
	case WildCard:
		return "wild"
	case WildDrawFour:
		return "wild4"
	}
	return fmt.Sprint(int(v))
}

// Card is a single physical card; ID is unique within a deck.
type Card struct {
	ID    int
	Color Color
	Value Value
}

func (c Card) IsWild() bool   { return c.Value == WildCard || c.Value == WildDrawFour }
func (c Card) IsNumber() bool { return c.Value >= 0 && c.Value <= 9 }

// Points is the score value of a card left in a loser's hand.
func (c Card) Points() int {
	switch {
	case c.IsNumber():
		return int(c.Value)
	case c.IsWild():
		return 50
	default:
		return 20
	}
}

// NewDeck returns the standard 108-card UNO deck, shuffled.
func NewDeck(rng *rand.Rand) []Card {
	deck := make([]Card, 0, 108)
	add := func(c Color, v Value) {
		deck = append(deck, Card{ID: len(deck), Color: c, Value: v})
	}
	for c := Red; c <= Blue; c++ {
		add(c, 0)
		for v := Value(1); v <= DrawTwo; v++ {
			add(c, v)
			add(c, v)
		}
	}
	for i := 0; i < 4; i++ {
		add(Wild, WildCard)
		add(Wild, WildDrawFour)
	}
	rng.Shuffle(len(deck), func(i, j int) { deck[i], deck[j] = deck[j], deck[i] })
	return deck
}
