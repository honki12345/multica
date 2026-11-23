package daemon

import (
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

// bareHermesFixture answers one ACP turn and records what the daemon sent it:
// the session/new request (MCP servers) and the session/prompt request (the
// turn text). It also records whether the workdir held an AGENTS.md at launch.
const bareHermesFixture = `#!/bin/sh
case "$*" in *--version*) echo 'hermes 0.22.0'; exit 0;; esac
if [ -f AGENTS.md ]; then cp AGENTS.md "$BARE_CAPTURE/agents.md"; fi
while IFS= read -r line; do
  id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
  case "$line" in
    *'"method":"initialize"'*)
      printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":1,"agentCapabilities":{"mcpCapabilities":{"http":true,"sse":true}}}}\n' "$id";;
    *'"method":"session/new"'*)
      printf '%s\n' "$line" > "$BARE_CAPTURE/session-new.json"
      printf '{"jsonrpc":"2.0","id":%s,"result":{"sessionId":"bare-session"}}\n' "$id";;
    *'"method":"session/prompt"'*)
      printf '%s\n' "$line" > "$BARE_CAPTURE/prompt.json"
      printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"bare-session","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"done"}}}}'
      printf '{"jsonrpc":"2.0","id":%s,"result":{"stopReason":"end_turn"}}\n' "$id"
      exit 0;;
    *) if [ -n "$id" ]; then printf '{"jsonrpc":"2.0","id":%s,"result":{}}\n' "$id"; fi;;
  esac
done
`

type bareCapture struct {
	agentsMD   string
	prompt     string
	mcpServers []any
}

func runBareHermesTask(t *testing.T, task Task) bareCapture {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("shell-script agent fixture is POSIX-only")
	}
	t.Setenv("HOME", t.TempDir())
	capture := t.TempDir()
	t.Setenv("BARE_CAPTURE", capture)
	fake := filepath.Join(t.TempDir(), "hermes")
	writeTestExecutable(t, fake, []byte(bareHermesFixture))
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{}`))
	}))
	defer srv.Close()
	d := &Daemon{
		client: NewClient(srv.URL), logger: logger,
		workspaces: make(map[string]*workspaceState), activeEnvRoots: make(map[string]int),
		activeStores: map[string]int{},
		runtimeIndex: map[string]Runtime{"test-rt": {ID: "test-rt", Provider: "hermes"}},
		cfg: Config{
			WorkspacesRoot: t.TempDir(), AgentTimeout: 10 * time.Second, ServerBaseURL: srv.URL,
			Agents: map[string]AgentEntry{"hermes": {Path: fake}},
		},
	}
	result, err := d.runTask(t.Context(), task, "hermes", 0, logger)
	if err != nil {
		t.Fatalf("runTask: %v", err)
	}
	if result.Status != "completed" || result.Comment != "done" {
		t.Fatalf("unexpected result: %+v", result)
	}

	var out bareCapture
	if raw, err := os.ReadFile(filepath.Join(capture, "agents.md")); err == nil {
		out.agentsMD = string(raw)
	}
	var prompt struct {
		Params struct {
			Prompt []struct {
				Text string `json:"text"`
			} `json:"prompt"`
		} `json:"params"`
	}
	readCapturedJSON(t, filepath.Join(capture, "prompt.json"), &prompt)
	if len(prompt.Params.Prompt) != 1 {
		t.Fatalf("prompt blocks = %d, want 1", len(prompt.Params.Prompt))
	}
	out.prompt = prompt.Params.Prompt[0].Text
	var session struct {
		Params struct {
			McpServers []any `json:"mcpServers"`
		} `json:"params"`
	}
	readCapturedJSON(t, filepath.Join(capture, "session-new.json"), &session)
	out.mcpServers = session.Params.McpServers
	return out
}

func readCapturedJSON(t *testing.T, path string, v any) {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	if err := json.Unmarshal(raw, v); err != nil {
		t.Fatalf("decode %s: %v", path, err)
	}
}

// The instruction phrases each prompt builder and brief section opens with.
// A bare run must contain none of them.
var bareForbiddenPhrases = []string{
	"You are running as",
	"Start by running",
	"Post your result",
	"Focus on THIS comment",
	"Multica Agent Runtime",
	"On Behalf Of",
	"Use `multica attachment download",
	"To include a file or image",
	"Audience:",
	"Before starting work, read the parent",
}

func bareTestAgent(runtimeConfig string) *AgentData {
	return &AgentData{
		ID: "test-agent", Name: "Hermes test", Instructions: "AGENT_INSTRUCTIONS_CANARY",
		McpConfig:     json.RawMessage(`{"mcpServers":{"canary":{"command":"canary-mcp"}}}`),
		RuntimeConfig: json.RawMessage(runtimeConfig),
	}
}

func bareTestIssueTask(runtimeConfig string) Task {
	return Task{
		ID: "test-task", WorkspaceID: "test-ws", RuntimeID: "test-rt", AgentID: "test-agent",
		AuthToken: "mat_test_bare", IssueID: "issue-1", IssueIdentifier: "CALA-1",
		TriggerCommentID: "comment-1", TriggerThreadID: "thread-1",
		TriggerCommentContent: "please fix the flaky test", TriggerAuthorType: "member",
		InitiatorName: "Hoon", InitiatorEmail: "hoon@example.com",
		ParentIssue: &ParentIssueData{ID: "parent-1", Identifier: "CALA-0", Title: "Parent", Status: "done"},
		Agent:       bareTestAgent(runtimeConfig),
	}
}

func TestRunTaskBareHermesCommentTurnCarriesOnlyFacts(t *testing.T) {
	got := runBareHermesTask(t, bareTestIssueTask(`{"bare":true}`))

	if got.agentsMD != "" {
		t.Fatalf("bare run wrote AGENTS.md into the workdir:\n%s", got.agentsMD)
	}
	if len(got.mcpServers) != 0 {
		t.Fatalf("bare run sent MCP servers: %v", got.mcpServers)
	}
	for _, phrase := range append(bareForbiddenPhrases, "AGENT_INSTRUCTIONS_CANARY") {
		if strings.Contains(got.prompt, phrase) {
			t.Fatalf("bare prompt contains instruction text %q:\n%s", phrase, got.prompt)
		}
	}
	for _, fact := range []string{
		"issue_id: issue-1",
		"issue_identifier: CALA-1",
		"trigger_comment_id: comment-1",
		"trigger_thread_id: thread-1",
		"parent_issue_id: parent-1",
		"on_behalf_of: Hoon <hoon@example.com>",
		"cli: $MULTICA_CLI_PATH",
		"please fix the flaky test",
	} {
		if !strings.Contains(got.prompt, fact) {
			t.Fatalf("bare prompt is missing fact %q:\n%s", fact, got.prompt)
		}
	}
}

func TestRunTaskBareHermesChatTurnCarriesMessageAndAttachments(t *testing.T) {
	task := Task{
		ID: "test-task", WorkspaceID: "test-ws", RuntimeID: "test-rt", AgentID: "test-agent",
		AuthToken: "mat_test_bare", ChatSessionID: "chat-1",
		ChatMessage:            "what changed today?",
		ChatMessageAttachments: []ChatAttachmentMeta{{ID: "att-1", Filename: "shot.png", ContentType: "image/png"}},
		Agent:                  bareTestAgent(`{"bare":true}`),
	}
	got := runBareHermesTask(t, task)

	if got.agentsMD != "" {
		t.Fatalf("bare chat wrote AGENTS.md:\n%s", got.agentsMD)
	}
	if len(got.mcpServers) != 0 {
		t.Fatalf("bare chat sent MCP servers: %v", got.mcpServers)
	}
	for _, phrase := range bareForbiddenPhrases {
		if strings.Contains(got.prompt, phrase) {
			t.Fatalf("bare chat prompt contains instruction text %q:\n%s", phrase, got.prompt)
		}
	}
	for _, fact := range []string{"chat_session_id: chat-1", "what changed today?", "att-1", "shot.png"} {
		if !strings.Contains(got.prompt, fact) {
			t.Fatalf("bare chat prompt is missing %q:\n%s", fact, got.prompt)
		}
	}
}

func TestRunTaskNonBareHermesKeepsBriefPromptAndMCP(t *testing.T) {
	for _, rc := range []string{``, `{}`, `{"bare":false}`} {
		t.Run("runtime_config="+rc, func(t *testing.T) {
			got := runBareHermesTask(t, bareTestIssueTask(rc))
			if !strings.Contains(got.agentsMD, "Multica Agent Runtime") || !strings.Contains(got.agentsMD, "AGENT_INSTRUCTIONS_CANARY") {
				t.Fatalf("non-bare run lost the runtime brief:\n%s", got.agentsMD)
			}
			if len(got.mcpServers) != 1 {
				t.Fatalf("non-bare run MCP servers = %v, want the agent's one", got.mcpServers)
			}
			if !strings.Contains(got.prompt, "You are running as a local coding agent") {
				t.Fatalf("non-bare prompt changed:\n%s", got.prompt)
			}
		})
	}
}

func TestBareRuntimeOnlyAppliesToHermes(t *testing.T) {
	agent := bareTestAgent(`{"bare":true}`)
	if !bareRuntime("hermes", agent) {
		t.Fatal("hermes agent with bare=true must run bare")
	}
	for _, provider := range []string{"claude", "codex", "openclaw", "opencode"} {
		if bareRuntime(provider, agent) {
			t.Fatalf("provider %s must ignore runtime_config.bare", provider)
		}
	}
	for _, rc := range []string{``, `{}`, `{"bare":false}`, `{"bare":"yes"}`, `not json`} {
		if bareRuntime("hermes", bareTestAgent(rc)) {
			t.Fatalf("runtime_config %q must not run bare", rc)
		}
	}
	if bareRuntime("hermes", nil) {
		t.Fatal("a task without agent data must not run bare")
	}
}

func TestBuildBarePromptPerRunKind(t *testing.T) {
	base := Task{WorkspaceID: "ws-1", AgentID: "agent-1", ID: "task-1"}
	cases := []struct {
		name string
		task Task
		want []string
	}{
		{"assignment", func() Task { t := base; t.IssueID = "issue-1"; t.HandoffNote = "only touch docs"; return t }(),
			[]string{"run: issue_assignment", "issue_id: issue-1", "only touch docs"}},
		{"wakeup", func() Task {
			t := base
			t.IssueID, t.WakeupID, t.HandoffNote, t.TriggerCommentID = "issue-1", "wake-1", "[WAKEUP]\ncheck the PR", "comment-9"
			return t
		}(), []string{"run: issue_wakeup", "wakeup_id: wake-1", "trigger_comment_id: comment-9", "check the PR"}},
		{"quick_create", func() Task {
			t := base
			t.QuickCreatePrompt, t.QuickCreatePriority, t.ProjectID, t.ParentIssueID = "add dark mode", "high", "proj-1", "parent-1"
			return t
		}(), []string{"run: quick_create", "priority: high", "project_id: proj-1", "parent_issue_id: parent-1", "add dark mode"}},
		{"autopilot", func() Task {
			t := base
			t.AutopilotRunID, t.AutopilotID, t.AutopilotDescription = "run-1", "ap-1", "summarize yesterday"
			return t
		}(), []string{"run: autopilot", "autopilot_run_id: run-1", "autopilot_id: ap-1", "summarize yesterday"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := buildBarePrompt(tc.task, "/work/dir")
			for _, want := range append(tc.want, "workdir: /work/dir", "workspace_id: ws-1", "task_id: task-1") {
				if !strings.Contains(got, want) {
					t.Fatalf("bare prompt is missing %q:\n%s", want, got)
				}
			}
			for _, phrase := range bareForbiddenPhrases {
				if strings.Contains(got, phrase) {
					t.Fatalf("bare prompt contains instruction text %q:\n%s", phrase, got)
				}
			}
		})
	}
}
