package main

import (
	"encoding/json"
	"log"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf8"
)

// Version is the server version, reported to clients in the welcome message.
const Version = "0.9.0-beta.5"

// versionLess compares versions like "0.9.0-beta.2". A release (no suffix)
// is newer than any pre-release of the same number. "" is older than anything.
func versionLess(a, b string) bool {
	if a == "" {
		return b != ""
	}
	an, ap := splitVersion(a)
	bn, bp := splitVersion(b)
	for i := 0; i < 3; i++ {
		if an[i] != bn[i] {
			return an[i] < bn[i]
		}
	}
	switch {
	case ap == bp:
		return false
	case ap == "":
		return false
	case bp == "":
		return true
	}
	// Compare pre-release like beta.2 vs beta.10 numerically where possible.
	aa, bb := strings.Split(ap, "."), strings.Split(bp, ".")
	for i := 0; i < len(aa) && i < len(bb); i++ {
		if aa[i] == bb[i] {
			continue
		}
		ai, e1 := strconv.Atoi(aa[i])
		bi, e2 := strconv.Atoi(bb[i])
		if e1 == nil && e2 == nil {
			return ai < bi
		}
		return aa[i] < bb[i]
	}
	return len(aa) < len(bb)
}

func splitVersion(v string) ([3]int, string) {
	var n [3]int
	v = strings.TrimPrefix(strings.TrimSpace(v), "v")
	pre := ""
	if i := strings.IndexByte(v, '-'); i >= 0 {
		v, pre = v[:i], v[i+1:]
	}
	for i, part := range strings.SplitN(v, ".", 3) {
		n[i], _ = strconv.Atoi(part)
	}
	return n, pre
}

// Feedback appends player reports to a JSON-lines file.
type Feedback struct {
	mu   sync.Mutex
	path string
}

type feedbackEntry struct {
	Time     time.Time       `json:"time"`
	User     string          `json:"user,omitempty"`
	Name     string          `json:"name"`
	Category string          `json:"category"`
	Text     string          `json:"text"`
	Info     json.RawMessage `json:"info,omitempty"`
	Log      string          `json:"log,omitempty"`
}

func clip(s string, n int) string {
	if len(s) <= n {
		return s
	}
	s = s[len(s)-n:] // keep the end (most recent log lines)
	for !utf8.ValidString(s) && len(s) > 0 {
		s = s[1:]
	}
	return s
}

func (h *Hub) handleFeedback(c *Client, m inMsg) {
	if h.feedback == nil {
		c.send(map[string]any{"t": "error", "msg": "this server doesn't collect feedback"})
		return
	}
	if c.feedbackSent >= 10 {
		c.send(map[string]any{"t": "error", "msg": "thanks! that's plenty of feedback for one session"})
		return
	}
	text := strings.TrimSpace(m.Text)
	if text == "" {
		c.send(map[string]any{"t": "error", "msg": "write something first"})
		return
	}
	c.feedbackSent++
	cat := strings.ToLower(m.Category)
	if cat != "bug" && cat != "idea" {
		cat = "other"
	}
	info := m.Info
	if len(info) > 4096 || !json.Valid(info) {
		info = nil
	}
	e := feedbackEntry{Time: time.Now().UTC(), User: c.user, Name: c.name, Category: cat,
		Text: clip(text, 4000), Info: info, Log: clip(m.Log, 16000)}
	b, _ := json.Marshal(e)
	h.feedback.mu.Lock()
	f, err := os.OpenFile(h.feedback.path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err == nil {
		_, err = f.Write(append(b, '\n'))
		f.Close()
	}
	h.feedback.mu.Unlock()
	if err != nil {
		log.Printf("feedback: %v", err)
		c.send(map[string]any{"t": "error", "msg": "couldn't save feedback, sorry"})
		return
	}
	log.Printf("feedback (%s) from %s", cat, c.name)
	if aw := h.appwrite; aw != nil {
		go func() {
			version := ""
			var inf map[string]any
			if json.Unmarshal(e.Info, &inf) == nil {
				version, _ = inf["version"].(string)
			}
			err := aw.CreateRow("feedback", "unique()", map[string]any{
				"user": e.User, "name": e.Name, "category": e.Category, "version": clip(version, 32),
				"text": e.Text, "info": string(e.Info), "log": e.Log})
			if err != nil {
				log.Printf("appwrite: feedback: %v", err)
			}
		}()
	}
	c.send(map[string]any{"t": "notice", "kind": "feedback_ok", "msg": "Thanks! Your feedback was sent."})
}
