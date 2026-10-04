package main

import (
	"encoding/json"
	"testing"
	"time"
)

func mustTime(t *testing.T, v string) time.Time {
	t.Helper()
	tm, err := time.Parse(time.RFC3339, v)
	if err != nil {
		t.Fatal(err)
	}
	return tm
}

// A player sits at a Blackjack table with a bot, plays three hands, and the
// chips always add up: chips + money on the table only changes by payouts.
func fastBlackjack(t *testing.T) {
	bet, results, dealer := bjBetTime, bjResultsTime, bjDealerStep
	bjBetTime, bjResultsTime, bjDealerStep = 3*time.Second, 300*time.Millisecond, 50*time.Millisecond
	t.Cleanup(func() { bjBetTime, bjResultsTime, bjDealerStep = bet, results, dealer })
}

func TestBlackjackTable(t *testing.T) {
	fastBlackjack(t)
	addr := startServer(t)
	a := dial(t, addr, "Ann")
	a.send(map[string]any{"t": "create", "game": "blackjack", "bots": 1, "settings": map[string]any{"minBet": 10, "maxBet": 100}})
	a.msg("seat")
	st := a.state("lobby", func(st stateJ) bool { return st.Phase == "lobby" && len(st.Players) == 2 })
	if st.Game != gameBlackjack || st.Settings.MaxPlayers != bjMaxSeats {
		t.Fatalf("game %q max %d", st.Game, st.Settings.MaxPlayers)
	}
	a.send(map[string]any{"t": "start"})
	me := st.You
	chips := guestChips
	hands := 0
	for hands < 3 {
		st = a.state("table", func(st stateJ) bool { return st.BJ != nil })
		bj := st.BJ
		var mine bjSeatJ
		for _, s := range bj.Seats {
			if s.ID == me {
				mine = s
			}
		}
		switch bj.Phase {
		case "betting":
			if mine.Bet == 0 {
				a.send(map[string]any{"t": "bet", "amount": 20})
				// Bad bets are refused.
				a.send(map[string]any{"t": "bet", "amount": 5000})
				if e := a.errorMsg(); e == "" {
					t.Fatal("over-limit bet accepted")
				}
			}
		case "playing":
			if bj.Turn == me {
				for _, h := range mine.Hands {
					if h.Active {
						if h.Total < 12 {
							a.send(map[string]any{"t": "hit"})
						} else {
							a.send(map[string]any{"t": "stand"})
						}
					}
				}
			}
		case "results":
			staked, paid := 0, 0
			for _, h := range mine.Hands {
				staked += h.Bet
				paid += h.Payout
			}
			if mine.Chips != chips-staked+paid {
				b, _ := json.Marshal(mine)
				t.Fatalf("chips %d, want %d - %d + %d: %s", mine.Chips, chips, staked, paid, b)
			}
			chips = mine.Chips
			hands++
			// Wait for the next betting round before counting again.
			a.state("next hand", func(st stateJ) bool { return st.BJ != nil && st.BJ.Phase == "betting" })
		}
	}
}

// Blackjack Quick Match starts right away and others sit down mid-game.
func TestBlackjackQuickJoinMidGame(t *testing.T) {
	addr := startServer(t)
	a := dial(t, addr, "Ann")
	a.send(map[string]any{"t": "quick", "game": "blackjack"})
	code := a.msg("seat")["code"].(string)
	a.state("running", func(st stateJ) bool { return st.BJ != nil && st.BJ.Phase == "betting" })
	a.send(map[string]any{"t": "bet", "amount": 10}) // deals at once: Ann's the only one
	a.state("dealt", func(st stateJ) bool { return st.BJ != nil && st.BJ.Phase != "betting" })

	b := dial(t, addr, "Ben")
	b.send(map[string]any{"t": "quick", "game": "blackjack"})
	if got := b.msg("seat")["code"]; got != code {
		t.Fatalf("Ben joined %v, want %s", got, code)
	}
	st := b.state("seated", func(st stateJ) bool { return st.BJ != nil && len(st.Players) == 2 })
	for _, s := range st.BJ.Seats {
		if s.ID == st.You && (s.Chips != guestChips || len(s.Hands) != 0) {
			t.Fatalf("newcomer seat %+v", s)
		}
	}
	// Glint Cards lobbies don't show Blackjack tables and vice versa.
	c := dial(t, addr, "Cat")
	c.send(map[string]any{"t": "list"})
	if rooms := c.msg("rooms")["rooms"].([]any); len(rooms) != 0 {
		t.Fatalf("Glint Cards list shows %v", rooms)
	}
	c.send(map[string]any{"t": "list", "game": "blackjack"})
	if rooms := c.msg("rooms")["rooms"].([]any); len(rooms) != 1 {
		t.Fatalf("Blackjack list shows %v", rooms)
	}
}

func TestChipGifts(t *testing.T) {
	u := &User{}
	now := mustTime(t, "2026-10-05T10:00:00Z")
	if g := applyChipGifts(u, now); g != "start" || u.Chips != StartingChips {
		t.Fatalf("start: %s %d", g, u.Chips)
	}
	if g := applyChipGifts(u, now.Add(time.Hour)); g != "" {
		t.Fatalf("gift an hour later: %s", g)
	}
	if g := applyChipGifts(u, now.Add(21*time.Hour)); g != "daily" || u.Chips != StartingChips+DailyBonus {
		t.Fatalf("daily: %s %d", g, u.Chips)
	}
	u.Chips = 0
	if g := applyChipGifts(u, now.Add(22*time.Hour)); g != "rescue" || u.Chips != RescueChips {
		t.Fatalf("rescue: %s %d", g, u.Chips)
	}
	u.Chips = 0
	if g := applyChipGifts(u, now.Add(22*time.Hour+time.Minute)); g != "" {
		t.Fatalf("second rescue within the hour: %s", g)
	}
}
