package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
)

// This filename is shared with the daemon's short-lived credential handoff.
const residentTaskContextFile = ".multica_resident_task.json"

type residentTaskCredential struct {
	TaskID      string `json:"task_id"`
	AgentID     string `json:"agent_id"`
	WorkspaceID string `json:"workspace_id"`
	Token       string `json:"token"`

	QuickCreateTaskID              string   `json:"quick_create_task_id"`
	QuickCreateAttachmentIDs       []string `json:"quick_create_attachment_ids"`
	QuickCreateDefaultAssigneeType string   `json:"quick_create_default_assignee_type"`
	QuickCreateDefaultAssigneeID   string   `json:"quick_create_default_assignee_id"`
}

// applyQuickCreateEnv exposes the resident task's quick-create context through
// the same MULTICA_QUICK_CREATE_* variables non-resident runs inherit, so
// `issue create` stamps origin and resolves --assignee-picker unchanged.
// Values already present in the environment win.
func (c *residentTaskCredential) applyQuickCreateEnv() {
	if c == nil || c.QuickCreateTaskID == "" {
		return
	}
	setIfEmpty := func(name, value string) {
		if value != "" && os.Getenv(name) == "" {
			_ = os.Setenv(name, value)
		}
	}
	setIfEmpty("MULTICA_QUICK_CREATE_TASK_ID", c.QuickCreateTaskID)
	if len(c.QuickCreateAttachmentIDs) > 0 {
		if raw, err := json.Marshal(c.QuickCreateAttachmentIDs); err == nil {
			setIfEmpty("MULTICA_QUICK_CREATE_ATTACHMENT_IDS", string(raw))
		}
	}
	setIfEmpty("MULTICA_QUICK_CREATE_DEFAULT_ASSIGNEE_TYPE", c.QuickCreateDefaultAssigneeType)
	setIfEmpty("MULTICA_QUICK_CREATE_DEFAULT_ASSIGNEE_ID", c.QuickCreateDefaultAssigneeID)
}

// Resident tools inherit the owner's environment, so discover task identity from their workdir.
func residentTaskCredentialFromCwd(token string) *residentTaskCredential {
	if os.Getenv("MULTICA_RESIDENT_OWNER") != "1" || os.Getenv("MULTICA_TASK_ID") != "" || strings.HasPrefix(token, "mat_") {
		return nil
	}
	dir, err := os.Getwd()
	if err != nil {
		return nil
	}
	for {
		data, err := os.ReadFile(filepath.Join(dir, residentTaskContextFile))
		if err == nil {
			var credential residentTaskCredential
			if json.Unmarshal(data, &credential) == nil && credential.TaskID != "" && strings.HasPrefix(credential.Token, "mat_") {
				return &credential
			}
			return nil
		}
		if !os.IsNotExist(err) {
			return nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return nil
		}
		dir = parent
	}
}
