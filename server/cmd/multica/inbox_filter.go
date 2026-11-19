package main

import (
	"encoding/json"
	"regexp"
	"slices"
	"sort"
	"strings"
	"time"
)

// The CLI's copy of the web Inbox filter (packages/core/inbox/filters.ts,
// filterInboxItems). packages/core/inbox/testdata/filter-parity.json holds
// cases both suites run, so the two cannot drift apart unnoticed.

// inboxTypeGroups maps each notification type to the group the web filter
// menu offers. Unlisted types are "system", as on the web.
var inboxTypeGroups = map[string]string{
	"mentioned":          "mention",
	"new_comment":        "comment",
	"reaction_added":     "comment",
	"issue_assigned":     "assign",
	"unassigned":         "assign",
	"assignee_changed":   "assign",
	"issue_subscribed":   "assign",
	"review_requested":   "review",
	"issue_created":      "change",
	"status_changed":     "change",
	"priority_changed":   "change",
	"start_date_changed": "change",
	"due_date_changed":   "change",
	"children_done":      "change",
	"task_completed":     "run",
	"task_failed":        "run",
	"agent_blocked":      "run",
	"agent_completed":    "run",
}

// inboxSystemTypes are the known types that fall in the "system" group.
var inboxSystemTypes = []string{
	"quick_create_done", "quick_create_failed", "quick_create_unconfirmed",
	"autopilot_paused", "autopilot_quota_exceeded", "project_owner_joined",
	"app_action_requested", "app_action_reminder", "app_connect_requested", "app_action_result",
}

var (
	inboxTypeGroupNames  = []string{"mention", "comment", "assign", "review", "change", "run", "system"}
	inboxReceivedFilters = []string{"today", "last_7_days", "last_30_days"}
	inboxDueFilters      = []string{"overdue", "today", "this_week", "next_7_days", "none"}
	inboxAgentFilters    = []string{"running", "idle"}
	inboxReceivedDays    = map[string]int{"today": 1, "last_7_days": 7, "last_30_days": 30}
)

const inboxNoneValue = "none"

func inboxTypeGroup(notificationType string) string {
	if group, ok := inboxTypeGroups[notificationType]; ok {
		return group
	}
	return "system"
}

// inboxRow is one notification as GET /api/inbox returns it.
type inboxRow struct {
	ID                string          `json:"id"`
	Type              string          `json:"type"`
	Title             string          `json:"title"`
	IssueID           *string         `json:"issue_id"`
	IssueStatus       *string         `json:"issue_status"`
	IssuePriority     *string         `json:"issue_priority"`
	IssueProjectID    *string         `json:"issue_project_id"`
	IssueAssigneeType *string         `json:"issue_assignee_type"`
	IssueAssigneeID   *string         `json:"issue_assignee_id"`
	IssueDueDate      *string         `json:"issue_due_date"`
	IssueLabelIDs     []string        `json:"issue_label_ids"`
	ActorType         *string         `json:"actor_type"`
	ActorID           *string         `json:"actor_id"`
	Read              bool            `json:"read"`
	CreatedAt         string          `json:"created_at"`
	SnoozedUntil      *string         `json:"snoozed_until"`
	Details           json.RawMessage `json:"details"`
	// Whether the row carried issue_priority at all, null included; an older
	// server omits it.
	hasPriority bool
}

func (r *inboxRow) UnmarshalJSON(data []byte) error {
	type plain inboxRow
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(data, &fields); err != nil {
		return err
	}
	if err := json.Unmarshal(data, (*plain)(r)); err != nil {
		return err
	}
	_, r.hasPriority = fields["issue_priority"]
	return nil
}

// commentID is the comment the notification is about, if any.
func (r inboxRow) commentID() string {
	var d struct {
		CommentID string `json:"comment_id"`
	}
	_ = json.Unmarshal(r.Details, &d)
	return d.CommentID
}

// inboxFilters mirrors the web's InboxFilters; the JSON names are the web's
// so the parity fixture decodes into it as is. Type values may also be raw
// notification types, which the web does not offer: they match that type
// exactly.
type inboxFilters struct {
	Types      []string `json:"types"`
	Actors     []string `json:"actors"`
	Received   string   `json:"received"`
	UnreadOnly bool     `json:"unreadOnly"`
	Statuses   []string `json:"statuses"`
	Priorities []string `json:"priorities"`
	Projects   []string `json:"projects"`
	Assignees  []string `json:"assignees"`
	Labels     []string `json:"labels"`
	DueDates   []string `json:"dueDates"`
	Agent      string   `json:"agent"`
	// Dimensions whose values are excluded rather than required, by their
	// web names (type, actor, status, priority, project, assignee, label,
	// dueDate).
	Negated []string `json:"negated"`
}

func (f inboxFilters) values(dimension string) []string {
	switch dimension {
	case "type":
		return f.Types
	case "actor":
		return f.Actors
	case "status":
		return f.Statuses
	case "priority":
		return f.Priorities
	case "project":
		return f.Projects
	case "assignee":
		return f.Assignees
	case "label":
		return f.Labels
	case "dueDate":
		return f.DueDates
	}
	return nil
}

var (
	inboxNotificationDimensions = []string{"type", "actor"}
	inboxIssueDimensions        = []string{"status", "priority", "project", "assignee", "label", "dueDate"}
)

func inboxActorKey(r inboxRow) string {
	if r.ActorType == nil || *r.ActorType == "" {
		return ""
	}
	if *r.ActorType == "system" {
		return "system"
	}
	if r.ActorID == nil || *r.ActorID == "" {
		return ""
	}
	return *r.ActorType + ":" + *r.ActorID
}

// inboxDimensionValues returns the values a row has in a dimension, and false
// when it has no issue to ask an issue question of.
func inboxDimensionValues(r inboxRow, dimension, today string) ([]string, bool) {
	switch dimension {
	case "type":
		return []string{inboxTypeGroup(r.Type), r.Type}, true
	case "actor":
		if key := inboxActorKey(r); key != "" {
			return []string{key}, true
		}
		return nil, true
	}
	if r.IssueID == nil {
		return nil, false
	}
	switch dimension {
	case "status":
		if r.IssueStatus == nil {
			return nil, false
		}
		return []string{*r.IssueStatus}, true
	case "priority":
		if r.IssuePriority == nil {
			return nil, false
		}
		return []string{*r.IssuePriority}, true
	case "project":
		if r.IssueProjectID == nil {
			return []string{inboxNoneValue}, true
		}
		// --project resolves to a lowercase UUID; the web compares the same
		// server-written value, which is already lowercase.
		return []string{strings.ToLower(*r.IssueProjectID)}, true
	case "assignee":
		if r.IssueAssigneeType == nil || *r.IssueAssigneeType == "" || r.IssueAssigneeID == nil || *r.IssueAssigneeID == "" {
			return []string{inboxNoneValue}, true
		}
		return []string{*r.IssueAssigneeType + ":" + *r.IssueAssigneeID}, true
	case "label":
		return r.IssueLabelIDs, true
	case "dueDate":
		var buckets []string
		for _, bucket := range inboxDueFilters {
			if inboxDueDateMatches(r.IssueDueDate, bucket, today) {
				buckets = append(buckets, bucket)
			}
		}
		return buckets, true
	}
	return nil, false
}

type inboxRowTest func(inboxRow) bool

func inboxDimensionTest(f inboxFilters, dimension, today string) inboxRowTest {
	selected := f.values(dimension)
	if len(selected) == 0 {
		return nil
	}
	negated := slices.Contains(f.Negated, dimension)
	return func(r inboxRow) bool {
		values, ok := inboxDimensionValues(r, dimension, today)
		// A notification without an issue answers no issue question, "is
		// not" included.
		if !ok {
			return false
		}
		return slices.ContainsFunc(values, func(v string) bool { return slices.Contains(selected, v) }) != negated
	}
}

type inboxCompiledFilters struct {
	notification []inboxRowTest
	issue        []inboxRowTest
}

func compileInboxFilters(f inboxFilters, now time.Time) inboxCompiledFilters {
	today := now.Format("2006-01-02")
	var compiled inboxCompiledFilters
	for _, dimension := range inboxNotificationDimensions {
		if test := inboxDimensionTest(f, dimension, today); test != nil {
			compiled.notification = append(compiled.notification, test)
		}
	}
	if f.Received != "" {
		after := inboxReceivedAfter(f.Received, now)
		compiled.notification = append(compiled.notification, func(r inboxRow) bool {
			created, ok := parseInboxTime(r.CreatedAt)
			return ok && !created.Before(after)
		})
	}
	for _, dimension := range inboxIssueDimensions {
		if test := inboxDimensionTest(f, dimension, today); test != nil {
			compiled.issue = append(compiled.issue, test)
		}
	}
	return compiled
}

func inboxPasses(tests []inboxRowTest, r inboxRow) bool {
	for _, test := range tests {
		if !test(r) {
			return false
		}
	}
	return true
}

func inboxAgentMatches(r inboxRow, agent string, activeIssueIDs map[string]bool) bool {
	if agent == "" {
		return true
	}
	if r.IssueID == nil {
		return false
	}
	return activeIssueIDs[*r.IssueID] == (agent == "running")
}

// inboxReceivedAfter is the start of the received window, at a local
// midnight so it holds all day.
func inboxReceivedAfter(received string, now time.Time) time.Time {
	y, m, d := now.Date()
	return time.Date(y, m, d-(inboxReceivedDays[received]-1), 0, 0, 0, 0, now.Location())
}

func parseInboxTime(s string) (time.Time, bool) {
	if s == "" {
		return time.Time{}, false
	}
	t, err := time.Parse(time.RFC3339Nano, s)
	return t, err == nil
}

var inboxDateOnly = regexp.MustCompile(`^(\d{4})-(\d{2})-(\d{2})`)

// inboxDayNumber reads a "YYYY-MM-DD" day, or a legacy full timestamp by its
// UTC day, as days since the epoch.
func inboxDayNumber(value string) (int64, bool) {
	var day time.Time
	if m := inboxDateOnly.FindStringSubmatch(value); m != nil {
		parsed, err := time.Parse("2006-01-02", m[1]+"-"+m[2]+"-"+m[3])
		if err != nil {
			return 0, false
		}
		day = parsed
	} else if parsed, ok := parseInboxTime(value); ok {
		day = parsed.UTC()
	} else {
		return 0, false
	}
	y, mo, d := day.Date()
	return time.Date(y, mo, d, 0, 0, 0, 0, time.UTC).Unix() / 86400, true
}

func inboxDueDateMatches(dueDate *string, bucket, today string) bool {
	due, hasDue := int64(0), false
	if dueDate != nil {
		due, hasDue = inboxDayNumber(*dueDate)
	}
	if bucket == inboxNoneValue {
		return !hasDue
	}
	now, ok := inboxDayNumber(today)
	if !hasDue || !ok {
		return false
	}
	switch bucket {
	case "overdue":
		return due < now
	case "today":
		return due == now
	case "this_week":
		weekday := int64(time.Unix(now*86400, 0).UTC().Weekday())
		monday := now - (weekday+6)%7
		return due >= monday && due < monday+7
	case "next_7_days":
		return due >= now && due < now+7
	}
	return false
}

func inboxSnoozeTime(r inboxRow) (time.Time, bool) {
	if r.SnoozedUntil == nil {
		return time.Time{}, false
	}
	return parseInboxTime(*r.SnoozedUntil)
}

// inboxRowTime is where a row sorts: when it arrived, or when it came back
// from a snooze, whichever is later.
func inboxRowTime(r inboxRow, now time.Time) time.Time {
	created, _ := parseInboxTime(r.CreatedAt)
	if at, ok := inboxSnoozeTime(r); ok && !at.After(now) && at.After(created) {
		return at
	}
	return created
}

func inboxGroupKey(r inboxRow) string {
	if r.IssueID != nil {
		return *r.IssueID
	}
	return r.ID
}

// groupInboxRows groups notifications by issue in first-seen order, each
// group newest first.
func groupInboxRows(items []inboxRow) [][]inboxRow {
	index := map[string]int{}
	var groups [][]inboxRow
	for _, r := range items {
		key := inboxGroupKey(r)
		if i, ok := index[key]; ok {
			groups[i] = append(groups[i], r)
			continue
		}
		index[key] = len(groups)
		groups = append(groups, []inboxRow{r})
	}
	for _, group := range groups {
		sort.SliceStable(group, func(i, j int) bool {
			a, _ := parseInboxTime(group[i].CreatedAt)
			b, _ := parseInboxTime(group[j].CreatedAt)
			return a.After(b)
		})
	}
	return groups
}

// filterInboxRows is the web Inbox list: one row per issue, its newest
// notification passing the notification dimensions (type, sender, received),
// then the issue dimensions and "only unread" asked of that row. OR within a
// dimension, AND between them, "is not" per dimension. Newest first, an issue
// back from a snooze counted from when it came back.
func filterInboxRows(items []inboxRow, f inboxFilters, activeIssueIDs map[string]bool, now time.Time) []inboxRow {
	tests := compileInboxFilters(f, now)
	out := make([]inboxRow, 0)
	for _, group := range groupInboxRows(items) {
		if at, ok := inboxSnoozeTime(group[0]); ok && at.After(now) {
			continue
		}
		i := slices.IndexFunc(group, func(r inboxRow) bool { return inboxPasses(tests.notification, r) })
		if i < 0 {
			continue
		}
		row := group[i]
		if !inboxPasses(tests.issue, row) || (f.UnreadOnly && row.Read) || !inboxAgentMatches(row, f.Agent, activeIssueIDs) {
			continue
		}
		out = append(out, row)
	}
	sort.SliceStable(out, func(i, j int) bool {
		return inboxRowTime(out[i], now).After(inboxRowTime(out[j], now))
	})
	return out
}

// filterInboxRowsUngrouped applies every dimension to each notification on
// its own and keeps the server's order.
func filterInboxRowsUngrouped(items []inboxRow, f inboxFilters, activeIssueIDs map[string]bool, now time.Time) []inboxRow {
	tests := compileInboxFilters(f, now)
	out := make([]inboxRow, 0)
	for _, r := range items {
		if !inboxPasses(tests.notification, r) || !inboxPasses(tests.issue, r) || (f.UnreadOnly && r.Read) || !inboxAgentMatches(r, f.Agent, activeIssueIDs) {
			continue
		}
		out = append(out, r)
	}
	return out
}
