// Modified by honki12345, 2026: bare Hermes runtime (no brief, no MCP, facts-only prompt).
package daemon

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/multica-ai/multica/server/internal/daemon/execenv"
	"github.com/multica-ai/multica/server/pkg/agent"
)

// injectRuntimeBrief writes the runtime brief into the workdir, or for a bare
// run writes nothing and returns no brief.
func injectRuntimeBrief(bare bool, workDir, provider string, ctx execenv.TaskContextForEnv) (string, error) {
	if bare {
		return "", nil
	}
	return execenv.InjectRuntimeConfig(workDir, provider, ctx)
}

// buildTaskPrompt is the per-turn input for this run: the facts-only prompt
// for a bare run, the platform prompt (with explicit skill invocation)
// otherwise.
func buildTaskPrompt(bare bool, task Task, provider string, env *execenv.Environment, options ...PromptOption) (string, *agent.SkillInvocation) {
	if bare {
		return buildBarePrompt(task, env.WorkDir), nil
	}
	return buildRuntimePrompt(task, provider, env.SkillDirectories, options...)
}

// bareRuntime reports whether this run starts Hermes without the Multica
// layer on top of it: no AGENTS.md runtime brief, no agent instructions, no
// MCP servers, and a per-turn prompt that states facts instead of directions.
// What the agent needs to know about Multica comes from its own skills.
//
// Opt-in per agent through runtime_config `{"bare": true}`, which the claim
// forwards verbatim; every other agent and provider keeps the full layer, and
// clearing the key restores it.
func bareRuntime(provider string, a *AgentData) bool {
	if provider != "hermes" || a == nil || len(a.RuntimeConfig) == 0 {
		return false
	}
	var cfg struct {
		Bare bool `json:"bare"`
	}
	return json.Unmarshal(a.RuntimeConfig, &cfg) == nil && cfg.Bare
}

// bareRunKind names which surface started the run. It decides which facts
// apply; the order matches buildPromptBodyWithOptions.
func bareRunKind(task Task) string {
	switch {
	case task.WakeupID != "":
		return "issue_wakeup"
	case task.ChatSessionID != "":
		return "chat"
	case task.TriggerCommentID != "":
		return "issue_comment"
	case task.AutopilotRunID != "":
		return "autopilot"
	case task.QuickCreatePrompt != "":
		return "quick_create"
	default:
		return "issue_assignment"
	}
}

// buildBarePrompt renders a bare run's whole turn input: one block of
// `key: value` facts, then the verbatim text a person or rule wrote for this
// run. It never says what to do; the agent decides that from the facts and
// its skills. Empty values are omitted.
func buildBarePrompt(task Task, workDir string) string {
	var facts [][2]string
	add := func(key, value string) {
		if value = strings.TrimSpace(value); value != "" {
			facts = append(facts, [2]string{key, value})
		}
	}
	kind := bareRunKind(task)
	add("run", kind)
	add("workspace_id", task.WorkspaceID)
	add("agent_id", task.AgentID)
	add("task_id", task.ID)
	add("workdir", workDir)
	add("cli", "$MULTICA_CLI_PATH")
	if task.InitiatorName != "" || task.InitiatorEmail != "" {
		who := strings.TrimSpace(task.InitiatorName)
		if email := strings.TrimSpace(task.InitiatorEmail); email != "" {
			who = strings.TrimSpace(who + " <" + email + ">")
		}
		add("on_behalf_of", who)
	}
	if task.PriorSessionResumeUnavailable {
		add("prior_session", "not restored")
	}

	add("issue_id", task.IssueID)
	add("issue_identifier", task.IssueIdentifier)
	if p := task.ParentIssue; p != nil && task.IssueID != "" {
		add("parent_issue_id", p.ID)
		add("parent_issue_identifier", p.Identifier)
	}
	add("trigger_comment_id", task.TriggerCommentID)
	add("trigger_thread_id", task.TriggerThreadID)
	if task.TriggerCommentID != "" {
		add("trigger_author", strings.TrimSpace(task.TriggerAuthorType+" "+task.TriggerAuthorName))
	}
	for _, cc := range task.CoalescedComments {
		add("also_comment", strings.TrimSpace(cc.ID+" thread="+cc.ThreadID))
	}
	if len(task.CoalescedComments) == 0 && len(task.CoalescedCommentIDs) > 0 {
		add("also_comment_ids", strings.Join(task.CoalescedCommentIDs, ","))
	}
	add("wakeup_id", task.WakeupID)
	add("wakeup_rule", task.WakeupSystemRule)

	add("chat_session_id", task.ChatSessionID)
	add("chat_channel", task.ChatChannelType)
	add("chat_type", task.ChatType)
	for _, a := range task.ChatMessageAttachments {
		add("attachment", strings.TrimSpace(fmt.Sprintf("%s %q %s", a.ID, a.Filename, a.ContentType)))
	}

	add("autopilot_run_id", task.AutopilotRunID)
	add("autopilot_id", task.AutopilotID)
	add("autopilot_source", task.AutopilotSource)

	if kind == "quick_create" {
		add("priority", task.QuickCreatePriority)
		add("due_date", task.QuickCreateDueDate)
		add("project_id", task.ProjectID)
		add("parent_issue_id", task.ParentIssueID)
		add("squad_id", task.SquadID)
		for _, id := range task.QuickCreateAttachmentIDs {
			add("attachment", id)
		}
	} else {
		add("project_id", task.ProjectID)
	}
	for _, r := range task.Repos {
		add("repo", strings.TrimSpace(r.URL+" "+r.Ref))
	}

	var b strings.Builder
	b.WriteString("[Multica run]\n")
	for _, f := range facts {
		fmt.Fprintf(&b, "%s: %s\n", f[0], f[1])
	}
	writeQuoted := func(title, body string) {
		if body = strings.TrimSpace(body); body == "" {
			return
		}
		fmt.Fprintf(&b, "\n[%s]\n%s\n", title, body)
	}
	switch kind {
	case "chat":
		message := task.ChatMessage
		if task.PriorSessionID != "" && task.ChatResumeMessage != nil {
			message = *task.ChatResumeMessage
		}
		writeQuoted("message", message)
	case "issue_comment":
		for _, cc := range task.CoalescedComments {
			writeQuoted("comment "+cc.ID, cc.Content)
		}
		writeQuoted("comment "+task.TriggerCommentID, task.TriggerCommentContent)
	case "issue_wakeup", "issue_assignment":
		writeQuoted("note", task.HandoffNote)
	case "autopilot":
		writeQuoted("autopilot", task.AutopilotDescription)
		writeQuoted("trigger payload", string(task.AutopilotTriggerPayload))
	case "quick_create":
		writeQuoted("quick create", task.QuickCreatePrompt)
		if len(task.QuickCreateSourceContext) > 0 {
			writeQuoted("source context", string(task.QuickCreateSourceContext))
		}
	}
	writeQuoted("joined wakeups", task.WakeupJoined)
	return b.String()
}
