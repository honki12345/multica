//go:build agentintegration

package agent

import (
	"context"
	"log/slog"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"
)

// TestHermesRealACPSteerSmoke drives the real `hermes acp` binary: a turn that
// must wait on a slow tool is steered with the answer it needs, and the same
// turn has to use it. HERMES_STEER_SMOKE_CWD picks the working directory.
func TestHermesRealACPSteerSmoke(t *testing.T) {
	requireRealAgentSmoke(t)
	path, err := exec.LookPath("hermes")
	if err != nil {
		t.Skip("hermes not on PATH")
	}
	version, _ := exec.Command(path, "--version").CombinedOutput()
	t.Logf("hermes version: %s", strings.SplitN(strings.TrimSpace(string(version)), "\n", 2)[0])
	if !SupportsTaskSupplement("hermes", string(version)) {
		t.Skip("hermes too old for /steer")
	}
	backend, err := New("hermes", Config{ExecutablePath: path, Logger: slog.Default(), BuiltinRuntime: true})
	if err != nil {
		t.Fatal(err)
	}
	cwd := os.Getenv("HERMES_STEER_SMOKE_CWD")
	if cwd == "" {
		cwd = t.TempDir()
	}
	ctx, cancel := context.WithTimeout(context.Background(), 280*time.Second)
	defer cancel()
	session, err := backend.Execute(ctx,
		"Steer test. First run the terminal command `sleep 25` in the foreground and wait for it to finish. "+
			"While it runs, the user will send you a code word as additional guidance. After the command finishes, "+
			"reply with exactly `CODE=<code word>` and nothing else. If no code word arrived, reply `CODE=NONE`. "+
			"Do not ask questions and do not use any other tools.",
		ExecOptions{Cwd: cwd, Timeout: 260 * time.Second, EnableTaskSupplement: true})
	if err != nil {
		t.Fatal(err)
	}
	if session.Supplement == nil {
		t.Fatal("supplement not exposed")
	}
	done := make(chan []Message, 1)
	go func() {
		var all []Message
		for m := range session.Messages {
			all = append(all, m)
		}
		done <- all
	}()
	deadline := time.Now().Add(120 * time.Second)
	for !session.SupplementReady() && time.Now().Before(deadline) {
		time.Sleep(200 * time.Millisecond)
	}
	if !session.SupplementReady() {
		t.Fatal("supplement never became ready")
	}
	// Give the model time to start the slow tool, so the steer lands mid-turn.
	time.Sleep(8 * time.Second)
	start := time.Now()
	steerErr := session.Supplement(ctx, "The code word is PINEAPPLE.")
	t.Logf("steer returned after %s: err=%v", time.Since(start).Round(time.Millisecond), steerErr)
	result := <-session.Result
	msgs := <-done
	t.Logf("status=%q error=%q output=%q session=%q messages=%d", result.Status, result.Error, result.Output, result.SessionID, len(msgs))
	if steerErr != nil {
		t.Fatalf("steer: %v", steerErr)
	}
	if result.Status != "completed" {
		t.Fatalf("status %q: %s", result.Status, result.Error)
	}
	if !strings.Contains(result.Output, "PINEAPPLE") {
		t.Fatalf("output %q does not use the steered code word", result.Output)
	}
	if strings.Contains(result.Output, "Steer queued") {
		t.Fatalf("steer acknowledgement leaked into output %q", result.Output)
	}
}
