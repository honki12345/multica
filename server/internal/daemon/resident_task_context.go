package daemon

import (
	"encoding/json"
	"os"
	"path/filepath"

	"github.com/multica-ai/multica/server/internal/daemon/execenv"
)

const residentTaskContextFile = ".multica_resident_task.json"

type residentTaskContext struct {
	TaskID        string `json:"task_id"`
	AgentID       string `json:"agent_id"`
	WorkspaceID   string `json:"workspace_id"`
	ChatSessionID string `json:"chat_session_id,omitempty"`
	Token         string `json:"token"`
	// AgentName and DaemonPort mirror MULTICA_AGENT_NAME / MULTICA_DAEMON_PORT
	// so daemon-local CLI commands (`repo checkout`, `env`) work from a
	// resident tool shell too.
	AgentName  string `json:"agent_name,omitempty"`
	DaemonPort int    `json:"daemon_port,omitempty"`
	// Quick-create context mirrors the MULTICA_QUICK_CREATE_* env the daemon
	// injects for non-resident runs; resident tool shells cannot inherit it.
	QuickCreateTaskID              string   `json:"quick_create_task_id,omitempty"`
	QuickCreateAttachmentIDs       []string `json:"quick_create_attachment_ids,omitempty"`
	QuickCreateDefaultAssigneeType string   `json:"quick_create_default_assignee_type,omitempty"`
	QuickCreateDefaultAssigneeID   string   `json:"quick_create_default_assignee_id,omitempty"`
}

// The resident owner outlives task environments, so its tools read a short-lived credential file.
func writeResidentTaskContext(envRoot, provider string, task Task, token, agentName string, daemonPort int) (func(), error) {
	noop := func() {}
	if !execenv.ResidentHermesGatewayEnabled() || provider != "hermes" || envRoot == "" {
		return noop, nil
	}
	ctx := residentTaskContext{
		TaskID:        task.ID,
		AgentID:       task.AgentID,
		WorkspaceID:   task.WorkspaceID,
		ChatSessionID: task.ChatSessionID,
		Token:         token,
		AgentName:     agentName,
		DaemonPort:    daemonPort,
	}
	if task.QuickCreatePrompt != "" {
		ctx.QuickCreateTaskID = task.ID
		ctx.QuickCreateAttachmentIDs = task.QuickCreateAttachmentIDs
		ctx.QuickCreateDefaultAssigneeType, ctx.QuickCreateDefaultAssigneeID = "agent", task.AgentID
		if task.SquadID != "" {
			ctx.QuickCreateDefaultAssigneeType, ctx.QuickCreateDefaultAssigneeID = "squad", task.SquadID
		}
	}
	data, err := json.Marshal(ctx)
	if err != nil {
		return noop, err
	}
	tmp, err := os.CreateTemp(envRoot, ".multica_resident_task-*.tmp")
	if err != nil {
		return noop, err
	}
	defer os.Remove(tmp.Name())
	// CreateTemp creates a private 0600 file before any credential bytes are written.
	_, writeErr := tmp.Write(data)
	closeErr := tmp.Close()
	if writeErr != nil {
		return noop, writeErr
	}
	if closeErr != nil {
		return noop, closeErr
	}
	path := filepath.Join(envRoot, residentTaskContextFile)
	if err := os.Rename(tmp.Name(), path); err != nil {
		return noop, err
	}
	return func() { _ = os.Remove(path) }, nil
}
