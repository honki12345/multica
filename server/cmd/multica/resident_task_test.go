package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/spf13/cobra"

	"github.com/multica-ai/multica/server/internal/daemon/execenv"
)

func TestResidentNewAPIClient(t *testing.T) {
	const valid = `{"task_id":"task-file","agent_id":"agent-file","workspace_id":"workspace-file","token":"mat_file"}`
	for _, tc := range []struct {
		name     string
		owner    string
		data     string
		task     string
		token    string
		marker   bool
		wantFile bool
		wantErr  bool
	}{
		{name: "nested", owner: "1", data: valid, wantFile: true},
		{name: "task marker guard satisfied", owner: "1", data: valid, marker: true, wantFile: true},
		{name: "owner member token replaced", owner: "1", data: valid, token: "mul_owner", marker: true, wantFile: true},
		{name: "owner opt-in required", data: valid},
		{name: "explicit task", owner: "1", data: valid, task: "task-explicit", token: "mat_explicit"},
		{name: "explicit task without token fails closed", owner: "1", data: valid, task: "task-explicit", wantErr: true},
		{name: "explicit token", owner: "1", data: valid, token: "mat_explicit"},
		{name: "malformed", owner: "1", data: "{"},
		{name: "member token", owner: "1", data: `{"task_id":"task-file","token":"mul_member"}`},
		{name: "missing identity", owner: "1", data: `{"token":"mat_file"}`},
		{name: "missing file guard unchanged", owner: "1", marker: true, wantErr: true},
		{name: "invalid file guard unchanged", owner: "1", data: "{", marker: true, wantErr: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			redirectTestHome(t, t.TempDir())
			t.Setenv("MULTICA_RESIDENT_OWNER", tc.owner)
			t.Setenv("MULTICA_TASK_ID", tc.task)
			t.Setenv("MULTICA_TOKEN", tc.token)
			t.Setenv("MULTICA_AGENT_ID", "")
			t.Setenv("MULTICA_DAEMON_PORT", "")
			t.Setenv("MULTICA_WORKSPACE_ID", "workspace-explicit")
			t.Setenv("MULTICA_SERVER_URL", "http://127.0.0.1:8080")
			root := t.TempDir()
			if tc.data != "" {
				if err := os.WriteFile(filepath.Join(root, ".multica_resident_task.json"), []byte(tc.data), 0o600); err != nil {
					t.Fatal(err)
				}
			}
			if tc.marker {
				path := filepath.Join(root, "workdir", execenv.TaskContextMarkerRelPath)
				if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(path, []byte(`{"managed_by":"`+execenv.TaskContextMarkerManagedBy+`","agent_id":"agent-file","issue_id":"issue-1"}`), 0o600); err != nil {
					t.Fatal(err)
				}
			}
			nested := filepath.Join(root, "workdir", "repo", "pkg")
			if err := os.MkdirAll(nested, 0o700); err != nil {
				t.Fatal(err)
			}
			t.Chdir(nested)
			client, err := newAPIClient(testCmd())
			if tc.wantErr {
				if err == nil || !strings.Contains(err.Error(), "mat_ token") {
					t.Fatalf("expected task token guard, got %v", err)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if tc.wantFile {
				if client.Token != "mat_file" || client.TaskID != "task-file" || client.AgentID != "agent-file" || client.WorkspaceID != "workspace-file" {
					t.Error("client did not use resident task identity and workspace")
				}
			} else if client.Token != tc.token || client.TaskID != tc.task || client.AgentID != "" || client.WorkspaceID != "workspace-explicit" {
				t.Error("client did not preserve explicit identity and workspace")
			}
		})
	}
}

func TestResidentQuickCreateAssigneePicker(t *testing.T) {
	const agentID = "8da18e1c-0f08-4a9c-b706-a68ba8975e54"
	quickFile := `{"task_id":"task-file","agent_id":"` + agentID + `","workspace_id":"workspace-file","token":"mat_file",` +
		`"quick_create_task_id":"task-file","quick_create_attachment_ids":["att-1"],` +
		`"quick_create_default_assignee_type":"agent","quick_create_default_assignee_id":"` + agentID + `"}`
	plainFile := `{"task_id":"task-file","agent_id":"` + agentID + `","workspace_id":"workspace-file","token":"mat_file"}`
	for _, tc := range []struct {
		name    string
		data    string
		wantErr string
	}{
		{name: "quick-create file", data: quickFile},
		{name: "non quick-create file still fails closed", data: plainFile, wantErr: "requires a quick-create task context"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			redirectTestHome(t, t.TempDir())
			t.Setenv("MULTICA_RESIDENT_OWNER", "1")
			for _, name := range []string{"MULTICA_TASK_ID", "MULTICA_TOKEN", "MULTICA_AGENT_ID", "MULTICA_DAEMON_PORT",
				"MULTICA_QUICK_CREATE_TASK_ID", "MULTICA_QUICK_CREATE_ATTACHMENT_IDS",
				"MULTICA_QUICK_CREATE_DEFAULT_ASSIGNEE_TYPE", "MULTICA_QUICK_CREATE_DEFAULT_ASSIGNEE_ID"} {
				t.Setenv(name, "")
			}
			t.Setenv("MULTICA_SERVER_URL", "http://127.0.0.1:8080")
			root := t.TempDir()
			if err := os.WriteFile(filepath.Join(root, ".multica_resident_task.json"), []byte(tc.data), 0o600); err != nil {
				t.Fatal(err)
			}
			t.Chdir(root)
			cmd := testCmd()
			cmd.Flags().Bool("assignee-picker", false, "")
			cmd.Flags().String("assignee", "", "")
			cmd.Flags().String("assignee-id", "", "")
			if err := cmd.Flags().Set("assignee-picker", "true"); err != nil {
				t.Fatal(err)
			}
			client, err := newAPIClient(cmd)
			if err != nil {
				t.Fatal(err)
			}
			aType, aID, ok, err := pickIssueCreateAssignee(context.Background(), client, cmd)
			if tc.wantErr != "" {
				if err == nil || !strings.Contains(err.Error(), tc.wantErr) {
					t.Fatalf("expected %q, got %v", tc.wantErr, err)
				}
				return
			}
			if err != nil || !ok || aType != "agent" || aID != agentID {
				t.Fatalf("picker = %q %q %v %v", aType, aID, ok, err)
			}
			if got := os.Getenv("MULTICA_QUICK_CREATE_TASK_ID"); got != "task-file" {
				t.Errorf("origin task id = %q", got)
			}
			ids, err := quickCreateAttachmentIDsFromEnv()
			if err != nil || len(ids) != 1 || ids[0] != "att-1" {
				t.Errorf("attachments = %v, %v", ids, err)
			}
		})
	}
}

// Resident tool shells inherit the owner's environment, not the daemon's
// per-task env, so daemon-local commands must find the task from the workdir.
func TestResidentDaemonLocalCommands(t *testing.T) {
	for _, tc := range []struct {
		name     string
		owner    string
		filePort bool
		wantOK   bool
	}{
		{name: "port from context file", owner: "1", filePort: true, wantOK: true},
		{name: "port from daemon.port fallback", owner: "1", wantOK: true},
		{name: "owner opt-in required", owner: "", filePort: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var gotAuth string
			var gotBody map[string]any
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				gotAuth = r.Header.Get("Authorization")
				_ = json.NewDecoder(r.Body).Decode(&gotBody)
				_ = json.NewEncoder(w).Encode(map[string]string{"path": "/work/repo", "branch_name": "agent/x/task"})
			}))
			defer srv.Close()
			u, _ := url.Parse(srv.URL)
			port, _ := strconv.Atoi(u.Port())

			home := t.TempDir()
			redirectTestHome(t, home)
			for _, name := range []string{"MULTICA_TASK_ID", "MULTICA_TOKEN", "MULTICA_AGENT_ID", "MULTICA_DAEMON_PORT", "MULTICA_WORKSPACE_ID", "MULTICA_AGENT_NAME"} {
				t.Setenv(name, "")
			}
			t.Setenv("MULTICA_RESIDENT_OWNER", tc.owner)
			if !tc.filePort {
				dir := filepath.Join(home, ".multica")
				if err := os.MkdirAll(dir, 0o700); err != nil {
					t.Fatal(err)
				}
				rec, _ := json.Marshal(daemonPortRecord{Port: port, PID: os.Getpid()})
				if err := os.WriteFile(filepath.Join(dir, "daemon.port"), rec, 0o600); err != nil {
					t.Fatal(err)
				}
			}
			ctx := map[string]any{"task_id": "task-file", "agent_id": "agent-file", "workspace_id": "ws-file", "token": "mat_file"}
			if tc.filePort {
				ctx["daemon_port"] = port
			}
			data, _ := json.Marshal(ctx)
			root := t.TempDir()
			if err := os.WriteFile(filepath.Join(root, ".multica_resident_task.json"), data, 0o600); err != nil {
				t.Fatal(err)
			}
			nested := filepath.Join(root, "workdir")
			if err := os.MkdirAll(nested, 0o700); err != nil {
				t.Fatal(err)
			}
			t.Chdir(nested)

			err := runRepoCheckout(&cobra.Command{}, []string{"https://github.com/org/repo.git"})
			if !tc.wantOK {
				if err == nil || !strings.Contains(err.Error(), "MULTICA_DAEMON_PORT not set") {
					t.Fatalf("expected unchanged missing-port error, got %v", err)
				}
				return
			}
			if err != nil {
				t.Fatalf("runRepoCheckout: %v", err)
			}
			if gotAuth != "Bearer mat_file" || gotBody["task_id"] != "task-file" || gotBody["workspace_id"] != "ws-file" {
				t.Fatalf("auth=%q body=%v", gotAuth, gotBody)
			}

			gotAuth = ""
			if err := callDaemonEnvironment(context.Background(), "/environments/list", map[string]any{}, &map[string]any{}, 5*time.Second); err != nil {
				t.Fatalf("callDaemonEnvironment: %v", err)
			}
			if gotAuth != "Bearer mat_file" {
				t.Fatalf("environment auth = %q", gotAuth)
			}
		})
	}
}
