package main

import (
	"encoding/json"

	"github.com/AndrewMommers/glint/server/uno"
)

// Wire protocol: newline-delimited JSON objects over TCP. Every message has
// a "t" field naming its type.
//
// Client -> server:
//   hello    {name}
//   list     {}                                   -> rooms
//   create   {name?, bots, settings}              -> state
//   join     {code}                               -> state
//   leave    {}                                   -> left
//   settings {settings}           (host, lobby)
//   add_bot  {difficulty?}        (host, lobby)
//   remove_bot {target}           (host, lobby)
//   start    {}                   (host; also starts the next round)
//   play     {card, color?, target?, uno?}
//   draw / pass / uno / catch {}
//   emote    {text}
//   ping     {}                                   -> pong
//
// Server -> client: welcome, state, rooms, error, emote, left, pong.

type inMsg struct {
	T          string          `json:"t"`
	Name       string          `json:"name"`
	Code       string          `json:"code"`
	Bots       int             `json:"bots"`
	Difficulty string          `json:"difficulty"`
	Settings   *settingsMsg    `json:"settings"`
	Card       int             `json:"card"`
	Color      string          `json:"color"`
	Target     string          `json:"target"`
	Uno        bool            `json:"uno"`
	Text       string          `json:"text"`
	Profile    *profile        `json:"profile"`
	Username   string          `json:"username"`
	Password   string          `json:"password"`
	Token      string          `json:"token"`
	XP         int             `json:"xp"`
	Level      int             `json:"level"`
	Data       json.RawMessage `json:"data"`
	Version    string          `json:"version"`
	Invite     string          `json:"invite"`
	Category   string          `json:"category"`
	Info       json.RawMessage `json:"info"`
	Log        string          `json:"log"`
}

// profile is the cosmetic identity a player shows to others.
type profile struct {
	Back  string `json:"back"`
	Frame string `json:"frame"`
	Level int    `json:"level"`
}

func (p profile) clean() profile {
	trim := func(s string) string {
		if len(s) > 24 {
			return s[:24]
		}
		return s
	}
	return profile{Back: trim(p.Back), Frame: trim(p.Frame), Level: clamp(p.Level, 1, 999)}
}

type settingsMsg struct {
	Rules       *uno.Rules `json:"rules"`
	TurnTime    *int       `json:"turnTime"`
	TargetScore *int       `json:"targetScore"`
	Difficulty  *string    `json:"difficulty"`
	Public      *bool      `json:"public"`
}

type settings struct {
	Rules       uno.Rules `json:"rules"`
	TurnTime    int       `json:"turnTime"`    // seconds per human turn, 0 = unlimited
	TargetScore int       `json:"targetScore"` // first to this many points wins the match, 0 = single rounds
	Difficulty  string    `json:"difficulty"`  // default bot difficulty
	Public      bool      `json:"public"`      // listed in the room browser
	MaxPlayers  int       `json:"maxPlayers"`
}

func (s *settings) apply(m *settingsMsg) {
	if m == nil {
		return
	}
	if m.Rules != nil {
		s.Rules = m.Rules.Normalize()
	}
	if m.TurnTime != nil {
		s.TurnTime = clamp(*m.TurnTime, 0, 120)
	}
	if m.TargetScore != nil {
		s.TargetScore = clamp(*m.TargetScore, 0, 2000)
	}
	if m.Difficulty != nil {
		s.Difficulty = uno.ParseDifficulty(*m.Difficulty).String()
	}
	if m.Public != nil {
		s.Public = *m.Public
	}
}

func clamp(v, lo, hi int) int {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

type cardJ struct {
	ID    int    `json:"id"`
	Color string `json:"color"`
	Value string `json:"value"`
}

func cardJSON(c uno.Card) cardJ {
	return cardJ{ID: c.ID, Color: c.Color.String(), Value: c.Value.String()}
}

type playerJ struct {
	ID         string `json:"id"`
	Name       string `json:"name"`
	Cards      int    `json:"cards"`
	Bot        bool   `json:"bot"`
	Difficulty string `json:"difficulty,omitempty"`
	Host       bool   `json:"host"`
	Score      int    `json:"score"`
	Vulnerable bool   `json:"vulnerable"`
	Back       string `json:"back"`
	Frame      string `json:"frame"`
	Level      int    `json:"level"`
}

type eventJ struct {
	Kind   string `json:"kind"`
	Player string `json:"player"`
	Target string `json:"target,omitempty"`
	Card   *cardJ `json:"card,omitempty"`
	Count  int    `json:"count,omitempty"`
	Color  string `json:"color,omitempty"`
}

type stateJ struct {
	T           string    `json:"t"`
	Code        string    `json:"code"`
	Phase       string    `json:"phase"` // lobby, playing, roundover, gameover
	You         string    `json:"you"`
	Host        string    `json:"host"`
	Settings    settings  `json:"settings"`
	Players     []playerJ `json:"players"`
	Round       int       `json:"round"`
	Hand        []cardJ   `json:"hand"`
	Top         *cardJ    `json:"top,omitempty"`
	Color       string    `json:"color,omitempty"`
	Turn        string    `json:"turn,omitempty"`
	Dir         int       `json:"dir"`
	DrawPile    int       `json:"drawPile"`
	Pending     int       `json:"pending"`
	Playable    []int     `json:"playable"`
	Drawn       int       `json:"drawn"` // id of the drawn card awaiting play/pass, -1 if none
	CanCatch    bool      `json:"canCatch"`
	CanUno      bool      `json:"canUno"`
	TimeLeft    float64   `json:"timeLeft"`
	Events      []eventJ  `json:"events"`
	Winner      string    `json:"winner,omitempty"`
	RoundPoints int       `json:"roundPoints"`
}

type roomInfo struct {
	Code    string `json:"code"`
	Host    string `json:"host"`
	Players int    `json:"players"`
	Max     int    `json:"max"`
}
