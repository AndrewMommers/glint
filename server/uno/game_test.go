package uno

import (
	"math/rand"
	"testing"
)

func totalCards(g *Game) int {
	n := len(g.DrawPile) + len(g.Discard)
	for _, p := range g.Players {
		n += len(p.Hand)
	}
	return n
}

func TestDeck(t *testing.T) {
	d := NewDeck(rand.New(rand.NewSource(1)))
	if len(d) != 108 {
		t.Fatalf("deck has %d cards", len(d))
	}
	wild := 0
	for _, c := range d {
		if c.IsWild() {
			wild++
		}
	}
	if wild != 8 {
		t.Fatalf("deck has %d wilds", wild)
	}
}

// Simulate many full bot games under every rule combination and check that
// cards are conserved and every round ends.
func TestBotGames(t *testing.T) {
	for mask := 0; mask < 32; mask++ {
		rules := Rules{
			HandSize:    7,
			Stacking:    mask&1 != 0,
			DrawToMatch: mask&2 != 0,
			ForcePlay:   mask&4 != 0,
			SevenO:      mask&8 != 0,
			JumpIn:      mask&16 != 0,
		}
		for seed := int64(0); seed < 40; seed++ {
			rng := rand.New(rand.NewSource(seed*100 + int64(mask)))
			n := 2 + int(seed%5)
			g := New(n, 0, rules, rng)
			for steps := 0; g.Winner < 0; steps++ {
				if steps > 5000 {
					t.Fatalf("rules %+v seed %d: game did not end", rules, seed)
				}
				// Occasionally let someone jump in or catch.
				for i := range g.Players {
					if rng.Intn(4) == 0 && g.CatchableBy(i) {
						g.Catch(i)
					}
					if i != g.Turn {
						if opts := g.PlayableCards(i); len(opts) > 0 && rng.Intn(3) == 0 {
							if _, err := g.Play(i, opts[0].ID, Red, -1, true); err != nil {
								t.Fatalf("jump-in failed: %v", err)
							}
						}
					}
				}
				if g.Winner >= 0 {
					break
				}
				pi := g.Turn
				m := BotMove(g, pi, Difficulty(seed%3), rng)
				var err error
				switch m.Kind {
				case "play":
					_, err = g.Play(pi, m.CardID, m.Color, m.Target, m.Uno)
				case "draw":
					_, err = g.DrawCard(pi)
				case "pass":
					_, err = g.Pass(pi)
				}
				if err != nil {
					t.Fatalf("rules %+v seed %d: %s failed: %v", rules, seed, m.Kind, err)
				}
				if c := totalCards(g); c != 108 {
					t.Fatalf("card count %d", c)
				}
			}
		}
	}
}

func TestStacking(t *testing.T) {
	g := New(3, 0, Rules{HandSize: 7, Stacking: true}, rand.New(rand.NewSource(3)))
	top := g.Top()
	g.Players[0].Hand = []Card{{ID: 200, Color: top.Color, Value: DrawTwo}, {ID: 201, Color: Red, Value: 1}}
	g.Players[1].Hand = []Card{{ID: 202, Color: Wild, Value: WildDrawFour}, {ID: 203, Color: Red, Value: 2}}
	g.Players[2].Hand = []Card{{ID: 204, Color: Blue, Value: 3}}
	if _, err := g.Play(0, 200, Red, -1, false); err != nil {
		t.Fatal(err)
	}
	if g.PendingDraw != 2 || g.Turn != 1 {
		t.Fatalf("pending %d turn %d", g.PendingDraw, g.Turn)
	}
	if _, err := g.Play(1, 203, Red, -1, false); err != ErrIllegal {
		t.Fatalf("number card should not stack, got %v", err)
	}
	if _, err := g.Play(1, 202, Blue, -1, false); err != nil {
		t.Fatal(err)
	}
	if _, err := g.DrawCard(2); err != nil {
		t.Fatal(err)
	}
	if len(g.Players[2].Hand) != 7 || g.Turn != 0 {
		t.Fatalf("player 2 has %d cards, turn %d", len(g.Players[2].Hand), g.Turn)
	}
}

func TestUnoCatch(t *testing.T) {
	g := New(2, 0, DefaultRules(), rand.New(rand.NewSource(5)))
	g.Players[0].Hand = []Card{{ID: 300, Color: Wild, Value: WildCard}, {ID: 301, Color: Red, Value: 5}}
	if _, err := g.Play(0, 300, Green, -1, false); err != nil {
		t.Fatal(err)
	}
	if !g.CatchableBy(1) {
		t.Fatal("player 0 should be catchable")
	}
	if _, err := g.Catch(1); err != nil {
		t.Fatal(err)
	}
	if len(g.Players[0].Hand) != 3 {
		t.Fatalf("caught player has %d cards", len(g.Players[0].Hand))
	}
}
