package blackjack

import (
	"math/rand"
	"testing"
)

func cards(ranks ...int) []Card {
	out := make([]Card, len(ranks))
	for i, r := range ranks {
		out[i] = Card{Rank: r, Suit: Suit(i % 4)}
	}
	return out
}

// stacked returns a shoe that deals the given ranks in order.
func stacked(ranks ...int) *Shoe {
	s := &Shoe{decks: 6, rng: rand.New(rand.NewSource(1))}
	s.shuffle()
	for i := len(ranks) - 1; i >= 0; i-- {
		s.cards = append(s.cards, Card{Rank: ranks[i], Suit: Hearts})
	}
	return s
}

func TestValue(t *testing.T) {
	for _, c := range []struct {
		ranks []int
		total int
		soft  bool
	}{
		{[]int{1, 13}, 21, true},
		{[]int{1, 1}, 12, true},
		{[]int{1, 6, 10}, 17, false},
		{[]int{1, 1, 9}, 21, true},
		{[]int{10, 12, 2}, 22, false},
		{[]int{5, 6}, 11, false},
	} {
		if total, soft := Value(cards(c.ranks...)); total != c.total || soft != c.soft {
			t.Errorf("Value(%v) = %d %v, want %d %v", c.ranks, total, soft, c.total, c.soft)
		}
	}
}

func TestDealAndSettle(t *testing.T) {
	// Deal order: seat0, dealer, seat0, dealer (one player).
	// Player 10+9 = 19, dealer 10+7 = 17 stands: player wins 1:1.
	r := Deal(stacked(10, 10, 9, 7), []int{100}, DefaultRules())
	if r.Turn != 0 || !r.HoleHidden() {
		t.Fatalf("turn %d hidden %v", r.Turn, r.HoleHidden())
	}
	r.Stand(0)
	for !r.DealerStep() {
	}
	if h := r.Seats[0].Hands[0]; h.Result != "win" || r.Payout(0) != 200 {
		t.Fatalf("result %s payout %d", h.Result, r.Payout(0))
	}
}

func TestBlackjackPaysThreeToTwo(t *testing.T) {
	// Player A+K, dealer 9+7 (no peek on a 9).
	r := Deal(stacked(1, 9, 13, 7), []int{100}, DefaultRules())
	for !r.DealerStep() {
	}
	if h := r.Seats[0].Hands[0]; h.Result != "blackjack" || r.Payout(0) != 250 {
		t.Fatalf("result %s payout %d", h.Result, r.Payout(0))
	}
}

func TestDealerPeekBlackjack(t *testing.T) {
	// Dealer shows an ace and has a king underneath: settled before anyone acts.
	r := Deal(stacked(10, 1, 9, 13), []int{50}, DefaultRules())
	if r.Phase != PhaseDone || r.Seats[0].Hands[0].Result != "lose" {
		t.Fatalf("phase %s result %s", r.Phase, r.Seats[0].Hands[0].Result)
	}
}

func TestDoubleAndSplit(t *testing.T) {
	// Player 8+8 splits; the hands get 3 and 2, then double the 11 (8+3) with a 10.
	r := Deal(stacked(8, 10, 8, 6, 3, 2, 10), []int{20}, DefaultRules())
	if !r.CanSplit(0) {
		t.Fatal("can't split 8s")
	}
	if err := r.Split(0); err != nil {
		t.Fatal(err)
	}
	if n := len(r.Seats[0].Hands); n != 2 {
		t.Fatalf("%d hands after split", n)
	}
	if err := r.Double(0); err != nil {
		t.Fatal(err)
	}
	if h := r.Seats[0].Hands[0]; h.Total() != 21 || h.Bet != 40 || !h.Done {
		t.Fatalf("doubled hand %v bet %d", h.Cards, h.Bet)
	}
	if r.Turn != 0 || r.Seats[0].Active != 1 {
		t.Fatalf("should move to the second hand, turn %d active %d", r.Turn, r.Seats[0].Active)
	}
	r.Stand(0) // 8+2 = 10
	for !r.DealerStep() {
	}
	if r.Staked(0) != 60 {
		t.Fatalf("staked %d, want 60", r.Staked(0))
	}
}

func TestBotsSimulation(t *testing.T) {
	rng := rand.New(rand.NewSource(7))
	shoe := NewShoe(6, rng)
	chips := []int{10000, 10000, 10000}
	for round := 0; round < 3000; round++ {
		if shoe.NeedsShuffle() {
			shoe.Reshuffle()
		}
		bets := []int{10, 50, 100}
		total := 0
		for i := range chips {
			chips[i] -= bets[i]
			total += bets[i]
		}
		r := Deal(shoe, bets, DefaultRules())
		for guard := 0; r.Phase == PhasePlaying; guard++ {
			if guard > 100 {
				t.Fatal("round never finished")
			}
			i := r.Turn
			h := r.Hand(i)
			switch BotMove(r, i, chips[i] >= h.Bet, chips[i] >= h.Bet) {
			case "double":
				chips[i] -= h.Bet
				r.Double(i)
			case "split":
				chips[i] -= h.Bet
				r.Split(i)
			case "hit":
				r.Hit(i)
			default:
				r.Stand(i)
			}
		}
		for !r.DealerStep() {
		}
		for i := range chips {
			if r.Payout(i) < 0 {
				t.Fatal("negative payout")
			}
			chips[i] += r.Payout(i)
		}
	}
	t.Logf("after 3000 rounds: %v (started 10000 each, wagering 10/50/100 a round)", chips)
	// Basic strategy loses slowly; it shouldn't be wildly off either way.
	for i, c := range chips {
		if c < 0 || c > 40000 {
			t.Errorf("seat %d ended with %d chips", i, c)
		}
	}
}
