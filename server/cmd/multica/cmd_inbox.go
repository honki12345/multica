// Modified by honki12345, 2026: filter and group `inbox list` the way the web Inbox does (CALA-248).

package main

import (
	"context"
	"fmt"
	"maps"
	"os"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"github.com/multica-ai/multica/server/internal/cli"
)

var inboxCmd = &cobra.Command{
	Use:   "inbox",
	Short: "Read your inbox notifications",
}

var inboxListCmd = &cobra.Command{
	Use:   "list",
	Short: "List your active notifications without changing read status",
	Long: `List your active notifications without changing read status. Agent tasks may read the runtime owner's inbox only when that owner is the task's verified upstream human originator; cloud-node credentials are refused.

The filters are the web Inbox's filters and mean the same thing. They apply locally after one read of the inbox. Values within a flag match ANY of them (repeat the flag or separate values with commas); different flags must ALL match; --not <dimension> turns that flag into "is not".

By default the list is the web Inbox list: one row per issue, newest first. The row is the issue's newest notification that passes --type, --actor and --received; --unread and the issue flags (--status, --priority, --project, --assignee, --label, --due, --agent) are then asked of that row. A notification without an issue never matches an issue flag, "is not" included. --ungrouped lists every matching notification instead, in server order.

Examples:
  multica inbox list --unread --type mention
  multica inbox list --project <id-prefix> --status todo,in_progress --not status
  multica inbox list --assignee none --due overdue,today --output json`,
	Args: exactArgs(0),
	RunE: runInboxList,
}

func init() {
	inboxCmd.AddCommand(inboxListCmd)
	registerInboxListFlags(inboxListCmd)
}

// inboxNegatableFlagNames are the --not values, in help order; each is the
// web's dimension name except --due (dueDate).
var inboxNegatableFlagNames = []string{"type", "actor", "status", "priority", "project", "assignee", "label", "due"}

func inboxDimensionOfFlag(flag string) string {
	if flag == "due" {
		return "dueDate"
	}
	return flag
}

// inboxKnownTypes are the exact notification types --type accepts besides the groups.
var inboxKnownTypes = slices.Sorted(slices.Values(append(slices.Collect(maps.Keys(inboxTypeGroups)), inboxSystemTypes...)))

func registerInboxListFlags(cmd *cobra.Command) {
	f := cmd.Flags()
	f.Bool("unread", false, "Only issues whose shown notification is unread")
	f.StringSlice("type", nil, "Notification type group ("+strings.Join(inboxTypeGroupNames, ", ")+") or exact notification type (e.g. mentioned)")
	f.StringSlice("actor", nil, "Who sent it: member or agent name, email, ID, member:<id>, agent:<id>, or system")
	f.String("received", "", "Received in the local calendar window: "+strings.Join(inboxReceivedFilters, ", "))
	f.StringSlice("status", nil, "Issue status (e.g. "+strings.Join(validIssueStatuses, ", ")+")")
	f.StringSlice("priority", nil, "Issue priority: "+strings.Join(validIssuePriorities, ", "))
	f.StringSlice("project", nil, "Issue project ID or unique ID prefix, or none")
	f.StringSlice("assignee", nil, "Issue assignee name, email, ID, <type>:<id>, or none")
	f.StringSlice("label", nil, "Issue label name, ID or unique ID prefix")
	f.StringSlice("due", nil, "Issue due date: "+strings.Join(inboxDueFilters, ", "))
	f.String("agent", "", "Whether an agent is running or queued on the issue: "+strings.Join(inboxAgentFilters, ", "))
	f.StringSlice("not", nil, "Exclude instead of require this flag's values: "+strings.Join(inboxNegatableFlagNames, ", "))
	f.Bool("ungrouped", false, "List every matching notification instead of one row per issue")
	f.String("output", "table", "Output format: table or json")
}

type inboxListItem struct {
	ID             string  `json:"id"`
	Type           string  `json:"type"`
	Title          string  `json:"title"`
	IssueID        *string `json:"issue_id"`
	CommentID      *string `json:"comment_id,omitempty"`
	IssueProjectID *string `json:"issue_project_id"`
	Read           bool    `json:"read"`
	CreatedAt      string  `json:"created_at"`
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

// parseInboxListFlags reads everything that needs no server: enum values are
// checked here, so a typo fails before any request. Name-like values are
// resolved later by resolveInboxListNames.
func parseInboxListFlags(cmd *cobra.Command) (inboxFilters, error) {
	var f inboxFilters
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

func runInboxList(cmd *cobra.Command, _ []string) error {
	output, _ := cmd.Flags().GetString("output")
	if output != "json" && output != "table" {
		return fmt.Errorf("output must be table or json")
	}
	filters, err := parseInboxListFlags(cmd)
	if err != nil {
		return err
	}
	client, err := newAPIClient(cmd)
	if err != nil {
		return err
	}
	ctx, cancel := cli.APIContext(cmd.Context())
	defer cancel()

	if err := resolveInboxListNames(ctx, client, &filters); err != nil {
		return err
	}

	var response []inboxRow
	if err := client.GetJSON(ctx, "/api/inbox", &response); err != nil {
		return fmt.Errorf("list inbox: %w", err)
	}
	if flag := inboxUnsupportedFlag(response, filters); flag != "" {
		return fmt.Errorf("this server does not send the issue fields --%s needs; upgrade the server or drop --%s", flag, flag)
	}
	var active map[string]bool
	if filters.Agent != "" {
		if active, err = inboxActiveIssueIDs(ctx, client); err != nil {
			return err
		}
	}

	now := time.Now()
	var rows []inboxRow
	if ungrouped, _ := cmd.Flags().GetBool("ungrouped"); ungrouped {
		rows = filterInboxRowsUngrouped(response, filters, active, now)
	} else {
		rows = filterInboxRows(response, filters, active, now)
	}

	items := make([]inboxListItem, 0, len(rows))
	for _, r := range rows {
		item := inboxListItem{ID: r.ID, Type: r.Type, Title: r.Title, IssueID: r.IssueID, IssueProjectID: r.IssueProjectID, Read: r.Read, CreatedAt: r.CreatedAt}
		if comment := r.commentID(); comment != "" {
			item.CommentID = &comment
		}
		items = append(items, item)
	}
	if output == "json" {
		return cli.PrintJSON(os.Stdout, items)
	}
	table := make([][]string, 0, len(items))
	value := func(s *string) string {
		if s == nil {
			return ""
		}
		return *s
	}
	for _, item := range items {
		table = append(table, []string{item.ID, item.Type, strings.Join(strings.Fields(item.Title), " "), value(item.IssueID), value(item.CommentID), value(item.IssueProjectID), strconv.FormatBool(item.Read), item.CreatedAt})
	}
	cli.PrintTable(os.Stdout, []string{"ID", "TYPE", "TITLE", "ISSUE", "COMMENT", "PROJECT", "READ", "CREATED"}, table)
	return nil
}
