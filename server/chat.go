package main

import (
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
)

const (
	chatMaxRunes = 140
	chatHistory  = 40
	chatBurst    = 5                // messages allowed per chatWindow
	chatWindow   = 10 * time.Second //
)

type chatJ struct {
	Player string `json:"player,omitempty"` // empty for system messages
	Name   string `json:"name,omitempty"`
	Text   string `json:"text"`
	Sys    bool   `json:"sys,omitempty"`
}

// cleanChat trims a chat line to one short line of printable text and masks
// profanity. It returns "" when nothing is left to say.
func cleanChat(s string) string {
	s = strings.Map(func(r rune) rune {
		switch {
		case r == '\n' || r == '\r' || r == '\t':
			return ' '
		case unicode.IsControl(r) || r == '​' || r == '‮':
			return -1
		}
		return r
	}, s)
	s = strings.Join(strings.Fields(s), " ")
	for utf8.RuneCountInString(s) > chatMaxRunes {
		_, size := utf8.DecodeLastRuneInString(s)
		s = s[:len(s)-size]
	}
	return maskProfanity(s)
}

// Words are matched after folding case and common look-alike characters, at
// the start of a word, so "classic" and "Scunthorpe" stay untouched.
var badWords = []string{
	"fuck", "shit", "bitch", "cunt", "dick", "pussy", "asshole", "bastard",
	"slut", "whore", "fag", "nigg", "retard", "twat", "wank", "kys",
}

var leet = map[rune]rune{'0': 'o', '1': 'i', '3': 'e', '4': 'a', '5': 's', '7': 't', '@': 'a', '$': 's', '!': 'i'}

func maskProfanity(s string) string {
	runes := []rune(s)
	folded := make([]rune, len(runes))
	for i, r := range runes {
		r = unicode.ToLower(r)
		if m, ok := leet[r]; ok {
			r = m
		}
		folded[i] = r
	}
	wordStart := func(i int) bool {
		return i == 0 || !(unicode.IsLetter(folded[i-1]) || unicode.IsDigit(runes[i-1]))
	}
	for i := range folded {
		if !wordStart(i) {
			continue
		}
		for _, w := range badWords {
			n := len([]rune(w))
			if i+n <= len(folded) && string(folded[i:i+n]) == w {
				// Mask the whole word, including any suffix ("-ing", "-s").
				j := i
				for j < len(runes) && (unicode.IsLetter(folded[j]) || unicode.IsDigit(runes[j])) {
					runes[j] = '*'
					j++
				}
				break
			}
		}
	}
	return string(runes)
}

// allowChat is a sliding-window rate limit; times holds recent send times.
func allowChat(times []time.Time, now time.Time) ([]time.Time, bool) {
	keep := times[:0]
	for _, t := range times {
		if now.Sub(t) < chatWindow {
			keep = append(keep, t)
		}
	}
	if len(keep) >= chatBurst {
		return keep, false
	}
	return append(keep, now), true
}
