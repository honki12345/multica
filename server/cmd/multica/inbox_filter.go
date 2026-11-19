package main

import (
	"context"
	"encoding/json"
	"fmt"
	"maps"
	"net/url"
	"regexp"
	"slices"
	"sort"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"github.com/multica-ai/multica/server/internal/cli"
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
	// CLI-only: upstream's --since (received at or after) and --issue (one
	// issue's notifications), both notification dimensions.
	Since time.Time `json:"-"`
	Issue string    `json:"-"`
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
	if !f.Since.IsZero() {
		compiled.notification = append(compiled.notification, func(r inboxRow) bool {
			created, ok := parseInboxTimestamp(r.CreatedAt)
			return ok && !created.Before(f.Since)
		})
	}
	if f.Issue != "" {
		compiled.notification = append(compiled.notification, func(r inboxRow) bool {
			return r.IssueID != nil && strings.EqualFold(*r.IssueID, f.Issue)
		})
	}
	if f.Received != "" {
		after := inboxReceivedAfter(f.Received, now)
		compiled.notification = append(compiled.notification, func(r inboxRow) bool {
			created, ok := parseInboxTimestamp(r.CreatedAt)
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

func parseInboxTimestamp(s string) (time.Time, bool) {
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
	} else if parsed, ok := parseInboxTimestamp(value); ok {
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
	return parseInboxTimestamp(*r.SnoozedUntil)
}

// inboxRowTime is where a row sorts: when it arrived, or when it came back
// from a snooze, whichever is later.
func inboxRowTime(r inboxRow, now time.Time) time.Time {
	created, _ := parseInboxTimestamp(r.CreatedAt)
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
			a, _ := parseInboxTimestamp(group[i].CreatedAt)
			b, _ := parseInboxTimestamp(group[j].CreatedAt)
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

// The fork's web Inbox filters on top of upstream `inbox list` (CALA-248,
// CALA-273). Upstream owns the command, its --project, --type, --unread,
// --issue, --since, --archived and --snoozed flags and its output; this file
// adds the web's other filters and its one-row-per-issue grouping, and hooks
// into runInboxList at flag parsing, the archive query and the filter step.

const inboxFilterHelp = "Filters are the web Inbox's filters and mean the same thing. Values within a flag match ANY of them (repeat the flag or separate values with commas); different flags must ALL match; --not <dimension> turns that flag into \"is not\". --type takes an exact notification type, as upstream does, or a type group.\n\n" +
	"By default the list is the web Inbox list: one row per issue, newest first. The row is the issue's newest notification that passes --type, --actor, --since and --received; --unread and the issue flags (--status, --priority, --project, --assignee, --label, --due, --agent) are then asked of that row, so --unread means \"the issue's shown notification is unread\". --ungrouped lists every matching notification instead, in server order, and asks --unread of each notification.\n\n" +
	"--archived sends the filters to the server, which applies the same rules to the archive; --agent and --ungrouped do not apply there. --snoozed takes no filter but --issue.\n\n"

const inboxUnreadUsage = "Only unread: the issue's shown notification by default, each notification with --ungrouped"

// inboxSnoozedRefusedFlags are the list flags --snoozed refuses; --issue is
// the one filter it takes.
var inboxSnoozedRefusedFlags = []string{"project", "type", "unread", "since", "actor", "received", "status", "priority", "assignee", "label", "due", "agent", "not", "ungrouped"}

// inboxKnownTypes are the exact notification types --type accepts besides
// the groups; a typo fails instead of listing nothing.
var inboxKnownTypes = slices.Sorted(slices.Values(append(slices.Collect(maps.Keys(inboxTypeGroups)), inboxSystemTypes...)))

// inboxNegatableFlagNames are the --not values, in help order; each is the
// web's dimension name except --due (dueDate).
var inboxNegatableFlagNames = []string{"type", "actor", "status", "priority", "project", "assignee", "label", "due"}

func inboxDimensionOfFlag(flag string) string {
	if flag == "due" {
		return "dueDate"
	}
	return flag
}

// registerInboxFilterFlags adds the web filters upstream `inbox list` lacks.
func registerInboxFilterFlags(cmd *cobra.Command) {
	f := cmd.Flags()
	f.StringSlice("actor", nil, "Who sent it: member or agent name, email, ID, member:<id>, agent:<id>, or system")
	f.String("received", "", "Received in the local calendar window, as the web presets: "+strings.Join(inboxReceivedFilters, ", ")+" (not with --since)")
	f.StringSlice("status", nil, "Issue status (e.g. "+strings.Join(validIssueStatuses, ", ")+")")
	f.StringSlice("priority", nil, "Issue priority: "+strings.Join(validIssuePriorities, ", "))
	f.StringSlice("assignee", nil, "Issue assignee name, email, ID, <type>:<id>, or none")
	f.StringSlice("label", nil, "Issue label name, ID or unique ID prefix")
	f.StringSlice("due", nil, "Issue due date: "+strings.Join(inboxDueFilters, ", "))
	f.String("agent", "", "Whether an agent is running or queued on the issue: "+strings.Join(inboxAgentFilters, ", "))
	f.StringSlice("not", nil, "Exclude instead of require this flag's values: "+strings.Join(inboxNegatableFlagNames, ", "))
	f.Bool("ungrouped", false, "List every matching notification instead of one row per issue")
}

func inboxAllowed(flag, value string, allowed []string) error {
	if slices.Contains(allowed, value) {
		return nil
	}
	return fmt.Errorf("invalid --%s %q; valid values: %s", flag, value, strings.Join(allowed, ", "))
}

func inboxFlagValues(cmd *cobra.Command, name string) []string {
	raw, _ := cmd.Flags().GetStringSlice(name)
	out := make([]string, 0, len(raw))
	for _, v := range raw {
		if v = strings.TrimSpace(v); v != "" && !slices.Contains(out, v) {
			out = append(out, v)
		}
	}
	return out
}

// inboxArchivedTypeSplit splits --type values into the type groups and the
// exact types the archive endpoint takes as separate parameters.
func inboxArchivedTypeSplit(types []string) (groups, exact []string) {
	for _, v := range types {
		if slices.Contains(inboxTypeGroupNames, v) {
			groups = append(groups, v)
		} else {
			exact = append(exact, v)
		}
	}
	return groups, exact
}

// parseInboxListFlags reads everything that needs no server, so a typo or an
// unsupported combination fails before any request. Name-like values are
// resolved later by resolveInboxListNames.
func parseInboxListFlags(cmd *cobra.Command, since time.Time, archived bool) (inboxFilters, error) {
	var f inboxFilters
	f.Since = since
	f.UnreadOnly, _ = cmd.Flags().GetBool("unread")
	for _, v := range inboxFlagValues(cmd, "type") {
		if !slices.Contains(inboxTypeGroupNames, v) && !slices.Contains(inboxKnownTypes, v) {
			return f, fmt.Errorf("invalid --type %q; valid groups: %s; or a notification type: %s",
				v, strings.Join(inboxTypeGroupNames, ", "), strings.Join(inboxKnownTypes, ", "))
		}
		f.Types = append(f.Types, v)
	}
	f.Received, _ = cmd.Flags().GetString("received")
	if f.Received != "" {
		if err := inboxAllowed("received", f.Received, inboxReceivedFilters); err != nil {
			return f, err
		}
		if !since.IsZero() {
			return f, fmt.Errorf("--received and --since cannot be combined; pick one received window")
		}
	}
	for _, v := range inboxFlagValues(cmd, "status") {
		if err := validateIssueStatus(v); err != nil {
			return f, err
		}
		f.Statuses = append(f.Statuses, strings.ToLower(v))
	}
	for _, v := range inboxFlagValues(cmd, "priority") {
		if err := inboxAllowed("priority", v, validIssuePriorities); err != nil {
			return f, err
		}
		f.Priorities = append(f.Priorities, v)
	}
	for _, v := range inboxFlagValues(cmd, "due") {
		if err := inboxAllowed("due", v, inboxDueFilters); err != nil {
			return f, err
		}
		f.DueDates = append(f.DueDates, v)
	}
	f.Agent, _ = cmd.Flags().GetString("agent")
	if f.Agent != "" {
		if err := inboxAllowed("agent", f.Agent, inboxAgentFilters); err != nil {
			return f, err
		}
	}
	// Name-like values are kept raw for now; their presence is what --not checks.
	f.Actors = inboxFlagValues(cmd, "actor")
	f.Projects = inboxFlagValues(cmd, "project")
	f.Assignees = inboxFlagValues(cmd, "assignee")
	f.Labels = inboxFlagValues(cmd, "label")
	for _, v := range inboxFlagValues(cmd, "not") {
		dimension := inboxDimensionOfFlag(v)
		if !slices.Contains(inboxNegatableFlagNames, v) {
			return f, fmt.Errorf("invalid --not %q; valid values: %s", v, strings.Join(inboxNegatableFlagNames, ", "))
		}
		if len(f.values(dimension)) == 0 {
			return f, fmt.Errorf("--not %s needs --%s values to exclude", v, v)
		}
		f.Negated = append(f.Negated, dimension)
	}
	if archived {
		for _, name := range []string{"agent", "ungrouped"} {
			if cmd.Flags().Changed(name) {
				return f, fmt.Errorf("--%s does not apply to --archived", name)
			}
		}
		// The archive endpoint ANDs its group and exact-type parameters and
		// negates only the groups, so neither mix can mean what the flags say.
		groups, exact := inboxArchivedTypeSplit(f.Types)
		if len(groups) > 0 && len(exact) > 0 {
			return f, fmt.Errorf("--archived takes either type groups (%s) or exact notification types in --type, not both", strings.Join(groups, ", "))
		}
		if len(exact) > 0 && slices.Contains(f.Negated, "type") {
			return f, fmt.Errorf("--archived --not type needs type groups (%s), not exact notification types", strings.Join(inboxTypeGroupNames, ", "))
		}
	}
	return f, nil
}

// resolveInboxActorRef resolves a name, email or ID, or a "<type>:<id>" key
// whose id may be a short ID, to the "<type>:<uuid>" form the rows carry.
func resolveInboxActorRef(ctx context.Context, client *cli.APIClient, flag, v string, kinds assigneeKinds) (string, error) {
	kind, id, typed := strings.Cut(v, ":")
	typed = typed && (kind == "member" || kind == "agent" || kind == "squad")
	if typed && uuidRegexp.MatchString(id) && (kind == "member" && kinds.member || kind == "agent" && kinds.agent || kind == "squad" && kinds.squad) {
		return kind + ":" + strings.ToLower(id), nil
	}
	lookup := v
	if typed {
		lookup = id
	}
	gotKind, gotID, err := resolveAssignee(ctx, client, lookup, kinds)
	if err != nil {
		return "", fmt.Errorf("resolve --%s: %w", flag, err)
	}
	if typed && gotKind != kind {
		return "", fmt.Errorf("resolve --%s: %q resolves to %s:%s, not %s", flag, v, gotKind, gotID, kind)
	}
	return gotKind + ":" + strings.ToLower(gotID), nil
}

// resolveInboxListNames turns names and ID prefixes into the ID forms the
// inbox rows carry.
func resolveInboxListNames(ctx context.Context, client *cli.APIClient, f *inboxFilters) error {
	for i, v := range f.Projects {
		if v == inboxNoneValue {
			continue
		}
		project, err := resolveProjectID(ctx, client, v)
		if err != nil {
			return err
		}
		f.Projects[i] = strings.ToLower(project.ID)
	}
	for i, v := range f.Assignees {
		if v == inboxNoneValue {
			continue
		}
		key, err := resolveInboxActorRef(ctx, client, "assignee", v, issueAssigneeKinds)
		if err != nil {
			return err
		}
		f.Assignees[i] = key
	}
	for i, v := range f.Actors {
		if v == "system" {
			continue
		}
		key, err := resolveInboxActorRef(ctx, client, "actor", v, memberOrAgentKinds)
		if err != nil {
			return err
		}
		f.Actors[i] = key
	}
	if len(f.Labels) > 0 {
		candidates, err := fetchLabelCandidates(ctx, client, "issue")
		if err != nil {
			return fmt.Errorf("resolve --label: %w", err)
		}
		ids, err := resolveIssueBatchLabels(ctx, client, candidates, f.Labels)
		if err != nil {
			return err
		}
		f.Labels = ids
	}
	return nil
}

// archivedInboxListQuery is the archive page query for the filters, in the
// parameters the web sends (archivedInboxQuery in packages/core/inbox), plus
// upstream's exact notification_types and group_id.
func archivedInboxListQuery(f inboxFilters, now time.Time) url.Values {
	q := url.Values{}
	list := func(name string, values []string) {
		if len(values) > 0 {
			sorted := slices.Sorted(slices.Values(values))
			q.Set(name, strings.Join(sorted, ","))
		}
	}
	groups, exact := inboxArchivedTypeSplit(f.Types)
	list("types", groups)
	list("notification_types", exact)
	list("actors", f.Actors)
	list("statuses", f.Statuses)
	list("priorities", f.Priorities)
	list("projects", f.Projects)
	list("assignees", f.Assignees)
	list("labels", f.Labels)
	list("due_dates", f.DueDates)
	list("negated", f.Negated)
	if len(f.DueDates) > 0 {
		q.Set("today", now.Format(time.DateOnly))
	}
	switch {
	case !f.Since.IsZero():
		q.Set("received_after", f.Since.UTC().Format(time.RFC3339Nano))
	case f.Received != "":
		q.Set("received_after", inboxReceivedAfter(f.Received, now).UTC().Format(time.RFC3339Nano))
	}
	if f.UnreadOnly {
		q.Set("unread_only", "true")
	}
	if f.Issue != "" {
		q.Set("group_id", f.Issue)
	}
	return q
}

// inboxUnsupportedFlag names a requested issue flag the server's rows cannot
// answer: an older server omits the fields. The web leaves such a filter
// dormant; the CLI says so instead of returning a different list.
func inboxUnsupportedFlag(rows []inboxRow, f inboxFilters) string {
	if len(rows) == 0 {
		return ""
	}
	allHave := func(has func(inboxRow) bool) bool {
		return !slices.ContainsFunc(rows, func(r inboxRow) bool { return !has(r) })
	}
	if len(f.Priorities) > 0 && !allHave(func(r inboxRow) bool { return r.hasPriority }) {
		return "priority"
	}
	if !allHave(func(r inboxRow) bool { return r.IssueLabelIDs != nil }) {
		for _, flag := range []struct {
			name   string
			values []string
		}{{"project", f.Projects}, {"assignee", f.Assignees}, {"label", f.Labels}, {"due", f.DueDates}} {
			if len(flag.values) > 0 {
				return flag.name
			}
		}
	}
	return ""
}

// inboxActiveIssueIDs is the set of issues an agent is running or queued on,
// by the rule the web Inbox and the issue rows use.
func inboxActiveIssueIDs(ctx context.Context, client *cli.APIClient) (map[string]bool, error) {
	var tasks []struct {
		IssueID  string `json:"issue_id"`
		Status   string `json:"status"`
		WakeupID string `json:"wakeup_id"`
	}
	if err := client.GetJSON(ctx, "/api/agent-task-snapshot", &tasks); err != nil {
		return nil, fmt.Errorf("read agent tasks for --agent: %w", err)
	}
	active := map[string]bool{}
	for _, t := range tasks {
		if t.IssueID == "" {
			continue
		}
		switch t.Status {
		case "running", "queued", "dispatched", "waiting_local_directory":
			active[t.IssueID] = true
		case "deferred":
			if t.WakeupID != "" {
				active[t.IssueID] = true
			}
		}
	}
	return active, nil
}

// UnmarshalJSON decodes a list row once for upstream's output and once for
// the web filter.
func (r *inboxListRow) UnmarshalJSON(data []byte) error {
	type plain inboxListRow
	if err := json.Unmarshal(data, (*plain)(r)); err != nil {
		return err
	}
	return json.Unmarshal(data, &r.filter)
}

// applyInboxListFilters is the filter step of `inbox list`. The archive
// comes one row per issue, filtered by the server; as upstream does, its rows
// are asked the notification filters and --unread again, so a server that
// ignores a parameter (notification_types before #10861) cannot widen it.
func applyInboxListFilters(ctx context.Context, client *cli.APIClient, rows []inboxListRow, f inboxFilters, archived, ungrouped bool) ([]inboxListRow, error) {
	if archived {
		tests := compileInboxFilters(f, time.Now())
		out := make([]inboxListRow, 0, len(rows))
		for _, r := range rows {
			if inboxPasses(tests.notification, r.filter) && !(f.UnreadOnly && r.Read) {
				out = append(out, r)
			}
		}
		return out, nil
	}
	filterRows := make([]inboxRow, len(rows))
	byID := make(map[string]inboxListRow, len(rows))
	for i, r := range rows {
		filterRows[i] = r.filter
		byID[r.ID] = r
	}
	if flag := inboxUnsupportedFlag(filterRows, f); flag != "" {
		return nil, fmt.Errorf("this server does not send the issue fields --%s needs; upgrade the server or drop --%s", flag, flag)
	}
	var active map[string]bool
	if f.Agent != "" {
		var err error
		if active, err = inboxActiveIssueIDs(ctx, client); err != nil {
			return nil, err
		}
	}
	var kept []inboxRow
	if ungrouped {
		kept = filterInboxRowsUngrouped(filterRows, f, active, time.Now())
	} else {
		kept = filterInboxRows(filterRows, f, active, time.Now())
	}
	out := make([]inboxListRow, 0, len(kept))
	for _, r := range kept {
		out = append(out, byID[r.ID])
	}
	return out, nil
}
