package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Appwrite is a minimal REST client for the parts of Appwrite (2.3, TablesDB)
// the server uses: Users, Account sessions (server-side rendering style) and
// TablesDB rows. The API key never leaves the server.
type Appwrite struct {
	Endpoint string // e.g. https://syd.cloud.appwrite.io/v1
	Project  string
	Key      string
	DB       string // TablesDB database id
	HC       *http.Client
}

// AppwriteConfig is the non-secret part, kept in beta/appwrite.json.
type AppwriteConfig struct {
	Endpoint string `json:"endpoint"`
	Project  string `json:"project"`
	Database string `json:"database"`
}

type awError struct {
	Status  int
	Type    string
	Message string
}

func (e *awError) Error() string {
	return fmt.Sprintf("appwrite %d %s: %s", e.Status, e.Type, e.Message)
}

func awStatus(err error) int {
	var e *awError
	if errors.As(err, &e) {
		return e.Status
	}
	return 0
}

func NewAppwrite(endpoint, project, key, db string) *Appwrite {
	if db == "" {
		db = "uno"
	}
	return &Appwrite{Endpoint: strings.TrimRight(endpoint, "/"), Project: project, Key: key, DB: db,
		HC: &http.Client{Timeout: 15 * time.Second}}
}

// loadAppwriteKey reads the API key from $APPWRITE_API_KEY or <data>/appwrite.key.
func loadAppwriteKey(dataDir string) string {
	if k := strings.TrimSpace(os.Getenv("APPWRITE_API_KEY")); k != "" {
		return k
	}
	b, err := os.ReadFile(filepath.Join(dataDir, "appwrite.key"))
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}

// call performs a request. With session != "" it acts as that user
// (X-Appwrite-Session); otherwise it uses the server API key.
func (aw *Appwrite) call(method, path string, body any, query url.Values, session string, out any) error {
	var rdr io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return err
		}
		rdr = bytes.NewReader(b)
	}
	u := aw.Endpoint + path
	if len(query) > 0 {
		u += "?" + query.Encode()
	}
	req, err := http.NewRequest(method, u, rdr)
	if err != nil {
		return err
	}
	req.Header.Set("X-Appwrite-Project", aw.Project)
	req.Header.Set("X-Appwrite-Response-Format", "2.3.0")
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	if session != "" {
		req.Header.Set("X-Appwrite-Session", session)
	} else if aw.Key != "" {
		req.Header.Set("X-Appwrite-Key", aw.Key)
	}
	resp, err := aw.HC.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if resp.StatusCode >= 400 {
		var e struct {
			Message string `json:"message"`
			Type    string `json:"type"`
		}
		json.Unmarshal(data, &e)
		if e.Message == "" {
			e.Message = strings.TrimSpace(string(data))
		}
		return &awError{Status: resp.StatusCode, Type: e.Type, Message: e.Message}
	}
	if out != nil && len(data) > 0 {
		return json.Unmarshal(data, out)
	}
	return nil
}

// ---- users & sessions ----

func (aw *Appwrite) CreateUser(name, email, password string) (string, error) {
	var u struct {
		ID string `json:"$id"`
	}
	err := aw.call("POST", "/users", map[string]any{"userId": "unique()", "email": email, "password": password, "name": name}, nil, "", &u)
	return u.ID, err
}

func (aw *Appwrite) SetLabels(userID string, labels []string) error {
	return aw.call("PUT", "/users/"+url.PathEscape(userID)+"/labels", map[string]any{"labels": labels}, nil, "", nil)
}

func (aw *Appwrite) DeleteUser(userID string) error {
	return aw.call("DELETE", "/users/"+url.PathEscape(userID), nil, nil, "", nil)
}

// CreateSession signs a user in with the API key (server-side rendering flow)
// and returns the session secret, which then authenticates as the user.
func (aw *Appwrite) CreateSession(email, password string) (secret, userID string, err error) {
	var s struct {
		Secret string `json:"secret"`
		UserID string `json:"userId"`
	}
	err = aw.call("POST", "/account/sessions/email", map[string]any{"email": email, "password": password}, nil, "", &s)
	if err == nil && s.Secret == "" {
		err = errors.New("appwrite returned no session secret (does the API key have the sessions.write scope?)")
	}
	return s.Secret, s.UserID, err
}

// GetAccount returns the user id the session secret belongs to.
func (aw *Appwrite) GetAccount(secret string) (string, error) {
	var u struct {
		ID string `json:"$id"`
	}
	err := aw.call("GET", "/account", nil, nil, secret, &u)
	return u.ID, err
}

func (aw *Appwrite) DeleteSession(secret string) error {
	return aw.call("DELETE", "/account/sessions/current", nil, nil, secret, nil)
}

// ---- TablesDB rows ----

func (aw *Appwrite) tablePath(table string) string {
	return "/tablesdb/" + url.PathEscape(aw.DB) + "/tables/" + url.PathEscape(table)
}

func (aw *Appwrite) CreateRow(table, rowID string, data map[string]any) error {
	return aw.call("POST", aw.tablePath(table)+"/rows", map[string]any{"rowId": rowID, "data": data}, nil, "", nil)
}

func (aw *Appwrite) UpdateRow(table, rowID string, data map[string]any) error {
	return aw.call("PATCH", aw.tablePath(table)+"/rows/"+url.PathEscape(rowID), map[string]any{"data": data}, nil, "", nil)
}

func awQuery(method string, values ...any) string {
	b, _ := json.Marshal(map[string]any{"method": method, "values": values})
	return string(b)
}

// ListAllRows pages through every row of a table.
func (aw *Appwrite) ListAllRows(table string) ([]map[string]any, error) {
	var all []map[string]any
	cursor := ""
	for {
		q := url.Values{}
		q.Add("queries[0]", awQuery("limit", 500))
		if cursor != "" {
			q.Add("queries[1]", awQuery("cursorAfter", cursor))
		}
		var page struct {
			Rows []map[string]any `json:"rows"`
		}
		if err := aw.call("GET", aw.tablePath(table)+"/rows", nil, q, "", &page); err != nil {
			return nil, err
		}
		all = append(all, page.Rows...)
		if len(page.Rows) < 500 {
			return all, nil
		}
		cursor, _ = page.Rows[len(page.Rows)-1]["$id"].(string)
	}
}

// ---- schema setup (glint-server appwrite-setup) ----

type awColumn struct {
	Kind     string // varchar, text, mediumtext, integer
	Key      string
	Size     int
	Required bool
	Array    bool
	Default  any
}

var awTables = []struct {
	ID, Name string
	Columns  []awColumn
	Unique   []string // unique single-column indexes
}{
	{"players", "Players", []awColumn{
		{Kind: "varchar", Key: "name", Size: 32, Required: true},
		{Kind: "varchar", Key: "appwriteId", Size: 36, Required: true},
		{Kind: "varchar", Key: "friends", Size: 32, Array: true},
		{Kind: "varchar", Key: "incoming", Size: 32, Array: true},
		{Kind: "varchar", Key: "outgoing", Size: 32, Array: true},
		{Kind: "integer", Key: "xp", Default: 0},
		{Kind: "integer", Key: "level", Default: 1},
		{Kind: "mediumtext", Key: "profile"},
		{Kind: "integer", Key: "chips", Default: 0},
		{Kind: "integer", Key: "bonusAt", Default: 0},
		{Kind: "integer", Key: "rescueAt", Default: 0},
	}, []string{"appwriteId"}},
	{"feedback", "Feedback", []awColumn{
		{Kind: "varchar", Key: "user", Size: 32},
		{Kind: "varchar", Key: "name", Size: 32},
		{Kind: "varchar", Key: "category", Size: 16},
		{Kind: "varchar", Key: "version", Size: 32},
		{Kind: "text", Key: "text"},
		{Kind: "text", Key: "info"},
		{Kind: "mediumtext", Key: "log"},
	}, nil},
}

// Setup creates the database, tables, columns and indexes if missing.
// Tables have no client permissions: only the server (API key) can access them.
func (aw *Appwrite) Setup(logf func(string, ...any)) error {
	// Check before creating: on plans with a database limit, creating an
	// existing database fails with "limit reached" instead of "exists".
	if err := aw.call("GET", "/tablesdb/"+url.PathEscape(aw.DB), nil, nil, "", nil); awStatus(err) == 404 {
		err = aw.call("POST", "/tablesdb", map[string]any{"databaseId": aw.DB, "name": "Glint"}, nil, "", nil)
		if err != nil && awStatus(err) != 409 {
			return fmt.Errorf("create database: %w", err)
		}
	} else if err != nil {
		return fmt.Errorf("database %q: %w", aw.DB, err)
	}
	logf("database %q ready", aw.DB)
	for _, t := range awTables {
		if err := aw.call("GET", aw.tablePath(t.ID), nil, nil, "", nil); awStatus(err) == 404 {
			err = aw.call("POST", "/tablesdb/"+url.PathEscape(aw.DB)+"/tables", map[string]any{
				"tableId": t.ID, "name": t.Name, "permissions": []string{}, "rowSecurity": false}, nil, "", nil)
			if err != nil && awStatus(err) != 409 {
				return fmt.Errorf("create table %s: %w", t.ID, err)
			}
		} else if err != nil {
			return fmt.Errorf("table %s: %w", t.ID, err)
		}
		for _, c := range t.Columns {
			body := map[string]any{"key": c.Key, "required": c.Required}
			if c.Size > 0 {
				body["size"] = c.Size
			}
			if c.Array {
				body["array"] = true
			}
			if c.Default != nil && !c.Required {
				body["default"] = c.Default
			}
			err := aw.call("POST", aw.tablePath(t.ID)+"/columns/"+c.Kind, body, nil, "", nil)
			if err != nil && awStatus(err) != 409 {
				return fmt.Errorf("create column %s.%s: %w", t.ID, c.Key, err)
			}
		}
		// Columns are created asynchronously; wait until they're available.
		for _, c := range t.Columns {
			if err := aw.waitColumn(t.ID, c.Key); err != nil {
				return err
			}
		}
		for _, col := range t.Unique {
			err := aw.call("POST", aw.tablePath(t.ID)+"/indexes", map[string]any{
				"key": "uniq_" + col, "type": "unique", "columns": []string{col}}, nil, "", nil)
			if err != nil && awStatus(err) != 409 {
				return fmt.Errorf("create index %s.%s: %w", t.ID, col, err)
			}
		}
		logf("table %q ready (%d columns)", t.ID, len(t.Columns))
	}
	return nil
}

func (aw *Appwrite) waitColumn(table, key string) error {
	for i := 0; i < 60; i++ {
		var c struct {
			Status string `json:"status"`
			Error  string `json:"error"`
		}
		if err := aw.call("GET", aw.tablePath(table)+"/columns/"+url.PathEscape(key), nil, nil, "", &c); err != nil {
			return fmt.Errorf("column %s.%s: %w", table, key, err)
		}
		switch c.Status {
		case "available":
			return nil
		case "failed", "stuck":
			return fmt.Errorf("column %s.%s failed: %s", table, key, c.Error)
		}
		time.Sleep(500 * time.Millisecond)
	}
	return fmt.Errorf("column %s.%s is still processing", table, key)
}

// runAppwriteSetup implements:
//
//	glint-server appwrite-setup -config beta/appwrite.json -data beta/server-data
func runAppwriteSetup(args []string) error {
	fs := flag.NewFlagSet("appwrite-setup", flag.ExitOnError)
	cfgPath := fs.String("config", "appwrite.json", "JSON file with endpoint, project, database")
	dataDir := fs.String("data", "data", "server data directory (for appwrite.key)")
	fs.Parse(args)
	b, err := os.ReadFile(*cfgPath)
	if err != nil {
		return err
	}
	var cfg AppwriteConfig
	if err := json.Unmarshal(b, &cfg); err != nil {
		return fmt.Errorf("%s: %w", *cfgPath, err)
	}
	key := loadAppwriteKey(*dataDir)
	if key == "" {
		return fmt.Errorf("no API key: set APPWRITE_API_KEY or create %s", filepath.Join(*dataDir, "appwrite.key"))
	}
	aw := NewAppwrite(cfg.Endpoint, cfg.Project, key, cfg.Database)
	if err := aw.Setup(func(f string, a ...any) { fmt.Printf(f+"\n", a...) }); err != nil {
		return err
	}
	fmt.Println("Appwrite is ready.")
	return nil
}
