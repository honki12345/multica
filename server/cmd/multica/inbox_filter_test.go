package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"testing"
	"time"
)

type inboxParityIssue struct {
	Status       *string  `json:"status"`
	Priority     *string  `json:"priority"`
	ProjectID    *string  `json:"project_id"`
	AssigneeType *string  `json:"assignee_type"`
	AssigneeID   *string  `json:"assignee_id"`
	DueDate      *string  `json:"due_date"`
	LabelIDs     []string `json:"label_ids"`
}

type inboxParityFixture struct {
	Now        string                      `json:"now"`
	TypeGroups map[string]string           `json:"type_groups"`
	Issues     map[string]inboxParityIssue `json:"issues"`
	Items      []struct {
		ID           string          `json:"id"`
		Type         string          `json:"type"`
		IssueID      *string         `json:"issue_id"`
		ActorType    *string         `json:"actor_type"`
		ActorID      *string         `json:"actor_id"`
		Read         bool            `json:"read"`
		CreatedAt    string          `json:"created_at"`
		SnoozedUntil string          `json:"snoozed_until"`
		Details      json.RawMessage `json:"details"`
	} `json:"items"`
	Cases []struct {
		Name           string       `json:"name"`
		Filters        inboxFilters `json:"filters"`
		ActiveIssueIDs []string     `json:"active_issue_ids"`
		Expected       []string     `json:"expected"`
	} `json:"cases"`
}

// localFixtureTime reads a fixture time, which carries no offset and means
// local wall-clock time, so the calendar-day dimensions agree in any zone.
func localFixtureTime(t *testing.T, s string) time.Time {
	t.Helper()
	at, err := time.ParseInLocation("2006-01-02T15:04:05", s, time.Local)
	if err != nil {
		t.Fatal(err)
	}
	return at
}

func loadInboxParityFixture(t *testing.T) (inboxParityFixture, []inboxRow, time.Time) {
	t.Helper()
	// Other tests in this package change the working directory, so find the
	// fixture from this file's location.
	_, self, _, _ := runtime.Caller(0)
	raw, err := os.ReadFile(filepath.Join(filepath.Dir(self), "..", "..", "..", "packages", "core", "inbox", "testdata", "filter-parity.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fx inboxParityFixture
	if err := json.Unmarshal(raw, &fx); err != nil {
		t.Fatal(err)
	}
	rows := make([]inboxRow, 0, len(fx.Items))
	for _, it := range fx.Items {
		row := inboxRow{
			ID: it.ID, Type: it.Type, IssueID: it.IssueID, ActorType: it.ActorType, ActorID: it.ActorID,
			Read: it.Read, CreatedAt: localFixtureTime(t, it.CreatedAt).Format(time.RFC3339), Details: it.Details,
		}
		if it.SnoozedUntil != "" {
			s := localFixtureTime(t, it.SnoozedUntil).Format(time.RFC3339)
			row.SnoozedUntil = &s
		}
		if it.IssueID != nil {
			issue := fx.Issues[*it.IssueID]
			row.IssueStatus, row.IssuePriority, row.IssueProjectID = issue.Status, issue.Priority, issue.ProjectID
			row.IssueAssigneeType, row.IssueAssigneeID, row.IssueDueDate = issue.AssigneeType, issue.AssigneeID, issue.DueDate
			row.IssueLabelIDs = issue.LabelIDs
		}
		rows = append(rows, row)
	}
	return fx, rows, localFixtureTime(t, fx.Now)
}

func TestInboxFilterParityWithWeb(t *testing.T) {
	fx, rows, now := loadInboxParityFixture(t)
	for notificationType, group := range fx.TypeGroups {
		if got := inboxTypeGroup(notificationType); got != group {
			t.Errorf("inboxTypeGroup(%q) = %q, web says %q", notificationType, got, group)
		}
	}
	for _, tc := range fx.Cases {
		t.Run(tc.Name, func(t *testing.T) {
			active := map[string]bool{}
			for _, id := range tc.ActiveIssueIDs {
				active[id] = true
			}
			got := filterInboxRows(rows, tc.Filters, active, now)
			ids := make([]string, 0, len(got))
			for _, r := range got {
				ids = append(ids, r.ID)
			}
			if !slices.Equal(ids, tc.Expected) {
				t.Fatalf("ids = %v, web shows %v", ids, tc.Expected)
			}
		})
	}
}

func TestInboxFilterCLIOnlyForms(t *testing.T) {
	_, rows, now := loadInboxParityFixture(t)
	run := func(f inboxFilters, ungrouped bool) []string {
		var got []inboxRow
		if ungrouped {
			got = filterInboxRowsUngrouped(rows, f, nil, now)
		} else {
			got = filterInboxRows(rows, f, nil, now)
		}
		ids := make([]string, 0, len(got))
		for _, r := range got {
			ids = append(ids, r.ID)
		}
		return ids
	}
	// A raw type matches that type only; its group would also take reactions.
	if got := run(inboxFilters{Types: []string{"reaction_added"}}, false); !slices.Equal(got, []string{"f-reaction"}) {
		t.Fatalf("raw type = %v", got)
	}
	if got := run(inboxFilters{Types: []string{"new_comment"}, Negated: []string{"type"}}, false); slices.Contains(got, "f-comment") || !slices.Contains(got, "f-app") {
		t.Fatalf("raw type is not = %v", got)
	}
	// Ungrouped keeps every matching notification in server order, snoozed included.
	if got := run(inboxFilters{Actors: []string{"member:alice"}}, true); !slices.Equal(got, []string{"a-comment", "b-mention", "d-comment", "e-mention"}) {
		t.Fatalf("ungrouped = %v", got)
	}
	if got := run(inboxFilters{UnreadOnly: true, Projects: []string{"p2"}}, true); !slices.Equal(got, []string{"f-reaction", "f-comment", "f-app"}) {
		t.Fatalf("ungrouped issue dimension = %v", got)
	}
}
