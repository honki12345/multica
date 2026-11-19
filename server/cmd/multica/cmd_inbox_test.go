// Modified by honki12345, 2026: cover the web Inbox filters and grouping on `inbox list` (CALA-248, CALA-273).

package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/spf13/cobra"
)

func runInboxListTest(t *testing.T, flags map[string]string) (string, error) {
	t.Helper()
	cmd := &cobra.Command{Use: "list"}
	registerInboxListFlags(cmd)
	for name, value := range flags {
		if err := cmd.Flags().Set(name, value); err != nil {
			t.Fatal(err)
		}
	}
	return captureStdout(t, func() error { return runInboxList(cmd, nil) })
}

func TestInboxListFiltersAndCommentAnchors(t *testing.T) {
	requests := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests++
		if r.Method != http.MethodGet || r.URL.RequestURI() != "/api/inbox" {
			t.Errorf("unexpected request: %s %s", r.Method, r.URL)
		}
		if r.Header.Get("X-Workspace-ID") != "ws-1" || r.Header.Get("Authorization") != "Bearer mat_inbox-test" {
			t.Error("lost workspace or task credential")
		}
		_, _ = w.Write([]byte(`[
			{"id":"n1","type":"mentioned","title":"Need input","issue_id":"i1","issue_project_id":"aaaaaaaa-1111-1111-1111-111111111111","issue_label_ids":[],"read":false,"created_at":"2026-11-16T08:00:00Z","details":{"comment_id":"c1","original_prompt":"not a list field"}},
			{"id":"n2","type":"mentioned","title":"Another project","issue_id":"i2","issue_project_id":"bbbbbbbb-2222-2222-2222-222222222222","issue_label_ids":[],"read":true},
			{"id":"n3","type":"new_comment","issue_id":"i3","issue_project_id":"aaaaaaaa-1111-1111-1111-111111111111","issue_label_ids":[],"details":{}},
			{"id":"n4","type":"system","issue_project_id":null,"issue_label_ids":[],"details":null}
		]`))
	}))
	defer srv.Close()
	t.Setenv("MULTICA_SERVER_URL", srv.URL)
	t.Setenv("MULTICA_WORKSPACE_ID", "ws-1")
	t.Setenv("MULTICA_TOKEN", "mat_inbox-test")
	t.Setenv("MULTICA_AGENT_ID", "agent-1")
	t.Setenv("MULTICA_TASK_ID", "task-1")

	for _, tc := range []struct {
		name  string
		flags map[string]string
		ids   string
	}{
		{"all", map[string]string{}, "n1,n2,n3,n4"},
		{"project", map[string]string{"project": "aaaaaaaa-1111-1111-1111-111111111111"}, "n1,n3"},
		{"type", map[string]string{"type": "mentioned"}, "n1,n2"},
		{"intersection", map[string]string{"project": "aaaaaaaa-1111-1111-1111-111111111111", "type": "mentioned"}, "n1"},
		{"empty", map[string]string{"project": "cccccccc-3333-3333-3333-333333333333"}, ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			tc.flags["output"] = "json"
			out, err := runInboxListTest(t, tc.flags)
			if err != nil {
				t.Fatal(err)
			}
			if strings.TrimSpace(out) == "null" {
				t.Fatal("empty list must be []")
			}
			var rows []map[string]any
			if err := json.Unmarshal([]byte(out), &rows); err != nil {
				t.Fatal(err)
			}
			ids := make([]string, 0, len(rows))
			for _, row := range rows {
				ids = append(ids, row["id"].(string))
				if _, ok := row["details"]; ok {
					t.Fatal("raw details leaked into list output")
				}
				if row["id"] == "n1" && (row["comment_id"] != "c1" || row["issue_id"] != "i1" || row["read"] != false || row["created_at"] != "2026-11-16T08:00:00Z") {
					t.Fatalf("lost notification fields: %v", row)
				}
				if row["id"] != "n1" {
					if _, ok := row["comment_id"]; ok {
						t.Fatalf("invented comment anchor: %v", row)
					}
				}
			}
			if strings.Join(ids, ",") != tc.ids {
				t.Fatalf("ids = %v, want %s", ids, tc.ids)
			}
		})
	}
	if requests != 5 {
		t.Fatalf("requests = %d, want one GET per invocation", requests)
	}
}

func TestInboxListTableAndDeniedRequest(t *testing.T) {
	const longTitle = "Need input on the archive pagination rewrite before the Friday release goes out"
	status := http.StatusOK
	requests := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests++
		if r.Method != http.MethodGet || r.URL.Path != "/api/inbox" {
			t.Errorf("unexpected request: %s %s", r.Method, r.URL)
		}
		w.WriteHeader(status)
		if status == http.StatusForbidden {
			_, _ = w.Write([]byte(`{"error":"inbox access denied"}`))
			return
		}
		_, _ = w.Write([]byte(`[{"id":"n1","type":"mentioned","title":"` + longTitle + `","issue_id":"i1","issue_project_id":"p1","read":true,"details":{"comment_id":"c1"}}]`))
	}))
	defer srv.Close()
	t.Setenv("MULTICA_SERVER_URL", srv.URL)
	t.Setenv("MULTICA_WORKSPACE_ID", "ws-1")
	t.Setenv("MULTICA_TOKEN", "mat_inbox-test")
	out, err := runInboxListTest(t, nil)
	if err != nil {
		t.Fatal(err)
	}
	header := strings.Fields(strings.SplitN(out, "\n", 2)[0])
	if want := []string{"ID", "TYPE", "TITLE", "ISSUE", "COMMENT", "PROJECT", "READ", "CREATED", "KEY", "FROM", "SUMMARY"}; strings.Join(header, " ") != strings.Join(want, " ") {
		t.Errorf("header = %v, want the original columns first, then %v", header, want[8:])
	}
	for _, value := range []string{"n1", longTitle, "i1", "c1", "p1", "true"} {
		if !strings.Contains(out, value) {
			t.Errorf("table missing %q: %s", value, out)
		}
	}
	status = http.StatusForbidden
	out, err = runInboxListTest(t, map[string]string{"output": "json"})
	if err == nil || out != "" {
		t.Fatalf("denied request: output=%q error=%v", out, err)
	}
	if requests != 2 {
		t.Fatalf("denial retried or fell back to another credential: %d requests", requests)
	}
	_, err = runInboxListTest(t, map[string]string{"output": "yaml"})
	if err == nil || requests != 2 {
		t.Fatalf("invalid output made request or succeeded: %v", err)
	}
}

func TestInboxListRegistered(t *testing.T) {
	cmd, _, err := rootCmd.Find([]string{"inbox", "list"})
	if err != nil || cmd.Name() != "list" || cmd.Parent().Name() != "inbox" {
		t.Fatalf("inbox list not registered: %v", err)
	}
	if cmd.Flags().Lookup("user") != nil {
		t.Fatal("inbox must not select another recipient")
	}
}

func TestInboxListResolvesProjectID(t *testing.T) {
	const projectA = "aaaaaaaa-1111-1111-1111-111111111111"
	const projectB = "bbbbbbbb-2222-2222-2222-222222222222"
	const collision = "aaaaaaaa-3333-3333-3333-333333333333"
	for _, tc := range []struct {
		name, input, wantID, wantError string
		projectRequests, inboxRequests int
	}{
		{"full UUID", projectB, "n2", "", 0, 1},
		{"uppercase full UUID", strings.ToUpper(projectB), "n2", "", 0, 1},
		{"unique short ID", "bbbbbbbb", "n2", "", 1, 1},
		{"longer prefix disambiguates", "aaaaaaaa-1111", "n1", "", 1, 1},
		{"no match", "deadbeef", "", `no project found matching id prefix "deadbeef"`, 1, 0},
		{"ambiguous prefix", "aaaaaaaa", "", `ambiguous project id prefix "aaaaaaaa"`, 1, 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			projectRequests, inboxRequests := 0, 0
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Method != http.MethodGet || r.Header.Get("X-Workspace-ID") != "ws-1" ||
					r.Header.Get("Authorization") != "Bearer mat_inbox-test" {
					t.Errorf("unexpected method or execution credentials: %s %s", r.Method, r.URL)
				}
				switch r.URL.Path {
				case "/api/projects":
					projectRequests++
					if r.URL.Query().Get("workspace_id") != "ws-1" || r.URL.Query().Get("include_archived") != "true" {
						t.Errorf("project resolution lost existing catalog scope: %s", r.URL)
					}
					_ = json.NewEncoder(w).Encode(map[string]any{"projects": []any{
						map[string]any{"id": projectA, "title": "A"},
						map[string]any{"id": projectB, "title": "B"},
						map[string]any{"id": collision, "title": "No notifications, but still ambiguous"},
					}})
				case "/api/inbox":
					inboxRequests++
					_ = json.NewEncoder(w).Encode([]map[string]any{
						{"id": "n1", "type": "mentioned", "issue_id": "i1", "issue_project_id": projectA, "issue_label_ids": []string{}},
						{"id": "n2", "type": "mentioned", "issue_id": "i2", "issue_project_id": projectB, "issue_label_ids": []string{}},
						{"id": "n3", "type": "new_comment", "issue_id": "i3", "issue_project_id": projectB, "issue_label_ids": []string{}},
					})
				default:
					t.Errorf("unexpected path: %s", r.URL)
					http.NotFound(w, r)
				}
			}))
			defer srv.Close()
			t.Setenv("MULTICA_SERVER_URL", srv.URL)
			t.Setenv("MULTICA_WORKSPACE_ID", "ws-1")
			t.Setenv("MULTICA_TOKEN", "mat_inbox-test")
			t.Setenv("MULTICA_AGENT_ID", "agent-1")
			t.Setenv("MULTICA_TASK_ID", "task-1")
			out, err := runInboxListTest(t, map[string]string{"project": tc.input, "type": "mentioned", "output": "json"})
			if tc.wantError != "" {
				if err == nil || !strings.Contains(err.Error(), tc.wantError) || out != "" {
					t.Fatalf("output=%q error=%v, want %s without list output", out, err, tc.wantError)
				}
				if tc.name == "ambiguous prefix" && (!strings.Contains(err.Error(), projectA) || !strings.Contains(err.Error(), collision)) {
					t.Fatalf("ambiguity error omitted matching project IDs: %v", err)
				}
			} else {
				if err != nil {
					t.Fatal(err)
				}
				var rows []struct {
					ID string `json:"id"`
				}
				if err := json.Unmarshal([]byte(out), &rows); err != nil {
					t.Fatal(err)
				}
				if len(rows) != 1 || rows[0].ID != tc.wantID {
					t.Fatalf("filtered output=%s, want %s", out, tc.wantID)
				}
			}
			if projectRequests != tc.projectRequests || inboxRequests != tc.inboxRequests {
				t.Fatalf("project/inbox requests=%d/%d, want %d/%d", projectRequests, inboxRequests, tc.projectRequests, tc.inboxRequests)
			}
		})
	}
}

func TestInboxListRejectsBadValuesBeforeAnyRequest(t *testing.T) {
	requests := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests++
		http.NotFound(w, r)
	}))
	defer srv.Close()
	t.Setenv("MULTICA_SERVER_URL", srv.URL)
	t.Setenv("MULTICA_WORKSPACE_ID", "ws-1")
	t.Setenv("MULTICA_TOKEN", "mat_inbox-test")
	for _, tc := range []struct {
		flags map[string]string
		want  string
	}{
		{map[string]string{"received": "yesterday"}, `invalid --received "yesterday"; valid values: today, last_7_days, last_30_days`},
		{map[string]string{"priority": "high,hgih"}, `invalid --priority "hgih"; valid values: urgent, high, medium, low, none`},
		{map[string]string{"due": "tomorrow"}, `invalid --due "tomorrow"; valid values: overdue, today, this_week, next_7_days, none`},
		{map[string]string{"agent": "busy"}, `invalid --agent "busy"; valid values: running, idle`},
		{map[string]string{"status": "In Review"}, `invalid status "In Review"`},
		{map[string]string{"not": "sender", "actor": "system"}, `invalid --not "sender"; valid values: type, actor, status, priority, project, assignee, label, due`},
		{map[string]string{"not": "label"}, `--not label needs --label values to exclude`},
	} {
		_, err := runInboxListTest(t, tc.flags)
		if err == nil || !strings.Contains(err.Error(), tc.want) {
			t.Errorf("%v: error = %v, want %q", tc.flags, err, tc.want)
		}
	}
	if requests != 0 {
		t.Fatalf("invalid flags reached the server %d times", requests)
	}
}

func TestInboxListResolvesNamesAndAgentState(t *testing.T) {
	const projectA = "aaaaaaaa-1111-1111-1111-111111111111"
	var paths []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			t.Errorf("inbox list must only read: %s %s", r.Method, r.URL)
		}
		paths = append(paths, r.URL.Path)
		switch r.URL.Path {
		case "/api/workspaces/ws-1/members":
			_ = json.NewEncoder(w).Encode([]map[string]any{{"user_id": "u-alice", "name": "Alice", "email": "alice@example.com"}, {"user_id": "u-carol", "name": "Carol"}})
		case "/api/agents":
			_ = json.NewEncoder(w).Encode([]map[string]any{{"id": "a-bob", "name": "Bob"}, {"id": "a-ops", "name": "Ops: Bot"}})
		case "/api/squads":
			_ = json.NewEncoder(w).Encode([]map[string]any{})
		case "/api/labels":
			_ = json.NewEncoder(w).Encode(map[string]any{"labels": []any{map[string]any{"id": "bbbbbbbb-0000-0000-0000-000000000001", "name": "Bug"}}})
		case "/api/agent-task-snapshot":
			_ = json.NewEncoder(w).Encode([]map[string]any{
				{"issue_id": "i1", "status": "running"},
				{"issue_id": "i2", "status": "deferred"},
				{"issue_id": "i3", "status": "deferred", "wakeup_id": "w-1"},
				{"issue_id": "i4", "status": "completed"},
			})
		case "/api/inbox":
			_, _ = w.Write([]byte(`[
				{"id":"n1","type":"mentioned","issue_id":"i1","issue_project_id":"` + strings.ToUpper(projectA) + `","issue_assignee_type":"member","issue_assignee_id":"u-carol","issue_label_ids":["bbbbbbbb-0000-0000-0000-000000000001"],"actor_type":"member","actor_id":"u-alice","read":false,"created_at":"2026-11-19T03:00:00Z","details":{"comment_id":"c1"}},
				{"id":"n1-old","type":"new_comment","issue_id":"i1","issue_project_id":"` + projectA + `","issue_assignee_type":"member","issue_assignee_id":"u-carol","issue_label_ids":["bbbbbbbb-0000-0000-0000-000000000001"],"actor_type":"agent","actor_id":"a-bob","read":true,"created_at":"2026-11-18T03:00:00Z","details":{"comment_id":"c0"}},
				{"id":"n2","type":"status_changed","issue_id":"i2","issue_project_id":null,"issue_label_ids":[],"actor_type":"agent","actor_id":"a-bob","read":false,"created_at":"2026-11-19T02:00:00Z"},
				{"id":"n3","type":"mentioned","issue_id":"i3","issue_project_id":null,"issue_label_ids":[],"actor_type":"member","actor_id":"u-alice","read":true,"created_at":"2026-11-19T01:00:00Z"},
				{"id":"n4","type":"autopilot_paused","issue_id":null,"issue_label_ids":[],"read":false,"created_at":"2026-11-19T04:00:00Z"}
			]`))
		default:
			t.Errorf("unexpected path: %s", r.URL)
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()
	t.Setenv("MULTICA_SERVER_URL", srv.URL)
	t.Setenv("MULTICA_WORKSPACE_ID", "ws-1")
	t.Setenv("MULTICA_TOKEN", "mat_inbox-test")

	ids := func(t *testing.T, flags map[string]string) string {
		t.Helper()
		flags["output"] = "json"
		paths = nil
		out, err := runInboxListTest(t, flags)
		if err != nil {
			t.Fatal(err)
		}
		var rows []struct {
			ID        string  `json:"id"`
			CommentID *string `json:"comment_id"`
		}
		if err := json.Unmarshal([]byte(out), &rows); err != nil {
			t.Fatal(err)
		}
		got := make([]string, 0, len(rows))
		for _, r := range rows {
			got = append(got, r.ID)
		}
		return strings.Join(got, ",")
	}
	for _, tc := range []struct {
		name  string
		flags map[string]string
		want  string
	}{
		{"grouped newest first", map[string]string{}, "n4,n1,n2,n3"},
		{"ungrouped keeps every notification", map[string]string{"ungrouped": "true"}, "n1,n1-old,n2,n3,n4"},
		{"type group and raw type", map[string]string{"type": "comment"}, "n1-old"},
		{"repeatable values by comma", map[string]string{"type": "mention,change"}, "n1,n2,n3"},
		{"actor by name", map[string]string{"actor": "Bob"}, "n2,n1-old"},
		{"actor by email, is not", map[string]string{"actor": "alice@example.com", "not": "actor"}, "n4,n2,n1-old"},
		{"actor system", map[string]string{"actor": "system"}, ""},
		{"assignee by name", map[string]string{"assignee": "carol"}, "n1"},
		{"assignee key with a short ID", map[string]string{"assignee": "member:u-carol"}, "n1"},
		{"actor name with a colon is a name", map[string]string{"actor": "Ops: Bot"}, ""},
		{"assignee none", map[string]string{"assignee": "none"}, "n2,n3"},
		{"label by name", map[string]string{"label": "bug"}, "n1"},
		{"project UUID matches an upper-case row", map[string]string{"project": "aaaaaaaa-1111-1111-1111-111111111111"}, "n1"},
		{"project none", map[string]string{"project": "none"}, "n2,n3"},
		{"unread asks the shown row", map[string]string{"unread": "true", "actor": "Bob"}, "n2"},
		{"agent running counts queued wakeups", map[string]string{"agent": "running"}, "n1,n3"},
		{"agent idle", map[string]string{"agent": "idle"}, "n2"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := ids(t, tc.flags); got != tc.want {
				t.Fatalf("ids = %q, want %q", got, tc.want)
			}
		})
	}
	ids(t, map[string]string{"type": "mention"})
	// Only upstream's sender-name lookup for the FROM column may follow.
	if len(paths) == 0 || paths[0] != "/api/inbox" || slices.ContainsFunc(paths, func(p string) bool {
		return p == "/api/labels" || p == "/api/projects" || p == "/api/agent-task-snapshot"
	}) {
		t.Fatalf("a filter that needs no lookup made extra requests: %v", paths)
	}
}

func TestInboxListRefusesIssueFlagsAnOlderServerCannotAnswer(t *testing.T) {
	legacy := `[{"id":"n1","type":"mentioned","issue_id":"i1","issue_status":"todo","read":false,"created_at":"2026-11-19T03:00:00Z"}]`
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/api/inbox":
			_, _ = w.Write([]byte(legacy))
		case "/api/workspaces/ws-1/members":
			_ = json.NewEncoder(w).Encode([]map[string]any{{"user_id": "u-carol", "name": "Carol"}})
		default:
			_ = json.NewEncoder(w).Encode([]any{})
		}
	}))
	defer srv.Close()
	t.Setenv("MULTICA_SERVER_URL", srv.URL)
	t.Setenv("MULTICA_WORKSPACE_ID", "ws-1")
	t.Setenv("MULTICA_TOKEN", "mat_inbox-test")
	for flag, value := range map[string]string{"priority": "high", "assignee": "none", "due": "none", "project": "none"} {
		_, err := runInboxListTest(t, map[string]string{flag: value, "output": "json"})
		if err == nil || !strings.Contains(err.Error(), "does not send the issue fields --"+flag) {
			t.Errorf("--%s on an older server: %v", flag, err)
		}
	}
	out, err := runInboxListTest(t, map[string]string{"status": "todo", "type": "mention", "output": "json"})
	if err != nil || !strings.Contains(out, `"n1"`) {
		t.Fatalf("status and type need no newer fields: out=%s err=%v", out, err)
	}
}

func TestInboxListKeepsEachRowsOwnCommentAndCurrentServerShape(t *testing.T) {
	const carol = "cccccccc-0000-0000-0000-000000000001"
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/api/inbox":
			// The current server: issue-less rows carry null issue fields and an empty label list.
			_, _ = w.Write([]byte(`[
				{"id":"mention","type":"mentioned","issue_id":"i1","issue_priority":"high","issue_assignee_type":"member","issue_assignee_id":"` + carol + `","issue_label_ids":[],"read":false,"created_at":"2026-11-19T03:00:00Z","details":{"comment_id":"c-new"}},
				{"id":"older","type":"new_comment","issue_id":"i1","issue_priority":"high","issue_assignee_type":"member","issue_assignee_id":"` + carol + `","issue_label_ids":[],"read":false,"created_at":"2026-11-19T01:00:00Z","details":{"comment_id":"c-old"}},
				{"id":"failed","type":"task_failed","issue_id":"i2","issue_priority":"low","issue_label_ids":[],"read":false,"created_at":"2026-11-19T02:00:00Z","details":{"task_id":"t-1"}},
				{"id":"system","type":"autopilot_paused","issue_id":null,"issue_priority":null,"issue_label_ids":[],"read":false,"created_at":"2026-11-19T00:00:00Z"}
			]`))
		case "/api/workspaces/ws-1/members":
			_ = json.NewEncoder(w).Encode([]map[string]any{{"user_id": carol, "name": "Carol"}})
		default:
			_ = json.NewEncoder(w).Encode([]any{})
		}
	}))
	defer srv.Close()
	t.Setenv("MULTICA_SERVER_URL", srv.URL)
	t.Setenv("MULTICA_WORKSPACE_ID", "ws-1")
	t.Setenv("MULTICA_TOKEN", "mat_inbox-test")
	list := func(flags map[string]string) map[string]any {
		t.Helper()
		flags["output"] = "json"
		out, err := runInboxListTest(t, flags)
		if err != nil {
			t.Fatal(err)
		}
		var rows []map[string]any
		if err := json.Unmarshal([]byte(out), &rows); err != nil {
			t.Fatal(err)
		}
		byID := map[string]any{}
		for _, r := range rows {
			byID[r["id"].(string)] = r["comment_id"]
		}
		return byID
	}
	// comment_id is the notification's own comment: something to reply to,
	// never another notification's comment or a task ID.
	if got := list(map[string]string{"type": "mention"}); len(got) != 1 || got["mention"] != "c-new" {
		t.Fatalf("grouped mention row = %v", got)
	}
	if got := list(map[string]string{"type": "run"}); len(got) != 1 || got["failed"] != nil {
		t.Fatalf("task_failed row = %v", got)
	}
	if got := list(map[string]string{"ungrouped": "true", "type": "comment"}); got["older"] != "c-old" {
		t.Fatalf("ungrouped row = %v", got)
	}
	if got := list(map[string]string{"priority": "high"}); len(got) != 1 {
		t.Fatalf("--priority refused or wrong on the current server shape: %v", got)
	}
	// "MEMBER:" is not a type prefix, so the whole value is looked up as a name.
	if _, err := runInboxListTest(t, map[string]string{"assignee": "MEMBER:" + carol, "output": "json"}); err == nil || !strings.Contains(err.Error(), `matching "MEMBER:`) {
		t.Fatalf("unknown prefix = %v", err)
	}
	if got := list(map[string]string{"assignee": "member:" + strings.ToUpper(carol)}); len(got) != 1 {
		t.Fatalf("upper-case member UUID key = %v", got)
	}
	_, err := runInboxListTest(t, map[string]string{"assignee": "agent:" + carol[:8], "output": "json"})
	if err == nil || !strings.Contains(err.Error(), "resolves to member:"+carol+", not agent") {
		t.Fatalf("type mismatch error = %v", err)
	}
}

// Upstream's --unread asks each notification; grouped, the web asks the row
// it shows. --ungrouped keeps upstream's meaning.
func TestInboxListUnreadGroupedAndUngrouped(t *testing.T) {
	now := time.Now().UTC()
	at := func(d time.Duration) string { return now.Add(-d).Format(time.RFC3339) }
	fakeInboxServer(t, map[string]func(http.ResponseWriter, *http.Request){
		"GET /api/inbox": reply(`[
			{"id":"` + inboxItemA + `","type":"status_changed","issue_id":"` + inboxIssue1 + `","issue_label_ids":[],"read":true,"created_at":"` + at(time.Hour) + `"},
			{"id":"` + inboxItemB + `","type":"mentioned","issue_id":"` + inboxIssue1 + `","issue_label_ids":[],"read":false,"created_at":"` + at(2*time.Hour) + `"},
			{"id":"` + inboxItemC + `","type":"mentioned","issue_id":"` + inboxIssue2 + `","issue_label_ids":[],"read":false,"created_at":"` + at(72*time.Hour) + `"}
		]`),
		"GET /api/issues": reply(`{"issues":[]}`),
	})
	for _, tc := range []struct {
		name  string
		flags map[string]string
		want  string
	}{
		{"grouped asks the shown row", map[string]string{"unread": "true"}, inboxItemC},
		{"ungrouped asks every notification", map[string]string{"unread": "true", "ungrouped": "true"}, inboxItemB + "," + inboxItemC},
		{"type picks the shown row first", map[string]string{"unread": "true", "type": "mention"}, inboxItemB + "," + inboxItemC},
		{"since is a notification filter", map[string]string{"since": "1d"}, inboxItemA},
		{"since picks an older row of the issue", map[string]string{"since": "1d", "type": "mentioned"}, inboxItemB},
		{"received preset", map[string]string{"received": "last_7_days", "issue": inboxIssue2}, inboxItemC},
	} {
		t.Run(tc.name, func(t *testing.T) {
			tc.flags["output"] = "json"
			out, err := runInboxCommand(t, registerInboxListFlags, func(cmd *cobra.Command, _ []string) error { return runInboxList(cmd, nil) }, nil, tc.flags)
			if err != nil {
				t.Fatal(err)
			}
			var rows []struct {
				ID string `json:"id"`
			}
			if err := json.Unmarshal([]byte(out), &rows); err != nil {
				t.Fatal(err)
			}
			got := make([]string, 0, len(rows))
			for _, r := range rows {
				got = append(got, r.ID)
			}
			if strings.Join(got, ",") != tc.want {
				t.Fatalf("ids = %v, want %s", got, tc.want)
			}
		})
	}
}

// The archive is filtered by the server: every web filter goes into the page
// query in the web's parameter names, beside upstream's exact type and issue.
func TestInboxListArchivedSendsWebFilters(t *testing.T) {
	var query url.Values
	fakeInboxServer(t, map[string]func(http.ResponseWriter, *http.Request){
		"GET /api/inbox/archived/page": func(w http.ResponseWriter, r *http.Request) {
			query = r.URL.Query()
			_, _ = w.Write([]byte(`{"items":[],"next_cursor":null,"has_more":false}`))
		},
	})
	list := func(cmd *cobra.Command, _ []string) error { return runInboxList(cmd, nil) }
	_, err := runInboxCommand(t, registerInboxListFlags, list, nil, map[string]string{
		"archived": "true", "type": "mention,comment", "not": "type,status", "status": "done,todo", "priority": "high",
		"actor": "system", "assignee": "none", "project": "none", "due": "overdue", "received": "today", "unread": "true", "output": "json",
	})
	if err != nil {
		t.Fatal(err)
	}
	for name, want := range map[string]string{
		"types": "comment,mention", "negated": "status,type", "statuses": "done,todo", "priorities": "high", "actors": "system",
		"assignees": "none", "projects": "none", "due_dates": "overdue", "today": time.Now().Format(time.DateOnly), "unread_only": "true",
	} {
		if got := query.Get(name); got != want {
			t.Errorf("%s = %q, want %q (query %v)", name, got, want, query)
		}
	}
	if query.Has("notification_types") || !query.Has("received_after") {
		t.Errorf("query = %v", query)
	}
}

// Combinations the archive, the snoozed list or the two received windows
// cannot answer as written fail before any request.
func TestInboxListRefusesFilterCombinationsBeforeAnyRequest(t *testing.T) {
	requests := fakeInboxServer(t, map[string]func(http.ResponseWriter, *http.Request){})
	list := func(cmd *cobra.Command, _ []string) error { return runInboxList(cmd, nil) }
	for _, tc := range []struct {
		flags map[string]string
		want  string
	}{
		{map[string]string{"since": "1d", "received": "today"}, "--received and --since cannot be combined"},
		{map[string]string{"archived": "true", "agent": "running"}, "--agent does not apply to --archived"},
		{map[string]string{"archived": "true", "ungrouped": "true"}, "--ungrouped does not apply to --archived"},
		{map[string]string{"archived": "true", "type": "mention,new_comment"}, "either type groups (mention) or exact notification types"},
		{map[string]string{"archived": "true", "type": "mentioned", "not": "type"}, "--archived --not type needs type groups"},
		{map[string]string{"snoozed": "true", "status": "todo"}, "--status does not apply to --snoozed"},
		{map[string]string{"snoozed": "true", "ungrouped": "true"}, "--ungrouped does not apply to --snoozed"},
		{map[string]string{"snoozed": "true", "actor": "system"}, "--actor does not apply to --snoozed"},
	} {
		_, err := runInboxCommand(t, registerInboxListFlags, list, nil, tc.flags)
		if err == nil || !strings.Contains(err.Error(), tc.want) {
			t.Errorf("%v: error = %v, want %q", tc.flags, err, tc.want)
		}
	}
	if len(*requests) != 0 {
		t.Fatalf("refused flags reached the server: %v", *requests)
	}
}

// A server older than #10861 ignores notification_types and returns every
// archived issue; the CLI still lists only the requested type, as upstream's
// own check after the request did.
func TestInboxListArchivedRechecksNotificationFiltersLocally(t *testing.T) {
	fakeInboxServer(t, map[string]func(http.ResponseWriter, *http.Request){
		"GET /api/inbox/archived/page": reply(`{"items":[
			{"id":"` + inboxItemA + `","type":"status_changed","title":"S","issue_id":"` + inboxIssue1 + `","read":true,"created_at":"2026-11-01T00:00:00Z"},
			{"id":"` + inboxItemB + `","type":"mentioned","title":"M","issue_id":"` + inboxIssue2 + `","read":false,"created_at":"2026-11-01T00:00:00Z"}
		],"next_cursor":null,"has_more":false}`),
		"GET /api/issues": reply(`{"issues":[]}`),
	})
	list := func(cmd *cobra.Command, _ []string) error { return runInboxList(cmd, nil) }
	for _, tc := range []struct {
		want  string
		flags map[string]string
	}{
		{inboxItemB, map[string]string{"type": "mentioned"}},
		{inboxItemB, map[string]string{"type": "mention"}},
		{inboxItemB, map[string]string{"unread": "true"}},
		{inboxItemA, map[string]string{"type": "mention", "not": "type"}},
	} {
		tc.flags["archived"], tc.flags["output"] = "true", "json"
		out, err := runInboxCommand(t, registerInboxListFlags, list, nil, tc.flags)
		if err != nil {
			t.Fatal(err)
		}
		var rows []struct {
			ID string `json:"id"`
		}
		if err := json.Unmarshal([]byte(out), &rows); err != nil {
			t.Fatal(err)
		}
		if len(rows) != 1 || rows[0].ID != tc.want {
			t.Errorf("%v: rows = %v, want only %s", tc.flags, rows, tc.want)
		}
	}
}
