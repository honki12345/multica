package agent

import (
	"context"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// fakeHermesSteerACPScript mirrors Hermes Agent 0.23's ACP `/steer` contract:
// the turn's session/prompt stays open; a second session/prompt whose text is
// `/steer <guidance>` is answered with a "⏩ Steer queued" agent message and an
// end_turn response, and the still-running turn then answers the guidance.
// HERMES_STEER_REPLY overrides the steer reply text (e.g. Hermes running it
// as a new prompt because no turn was active).
func fakeHermesSteerACPScript() string {
	return `#!/bin/sh
prompt_id=""
while IFS= read -r line; do
  if [ -n "$HERMES_REQUESTS_FILE" ]; then
    printf '%s\n' "$line" >> "$HERMES_REQUESTS_FILE"
  fi
  id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
  case "$line" in
    *'"method":"initialize"'*)
      printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":1,"agentCapabilities":{}}}\n' "$id"
      ;;
    *'"method":"session/new"'*)
      printf '{"jsonrpc":"2.0","id":%s,"result":{"sessionId":"ses_steer"}}\n' "$id"
      ;;
    *'"text":"/steer '*)
      reply='⏩ Steer queued for the active turn: The word is PINEAPPLE.'
      if [ -n "$HERMES_STEER_REPLY" ]; then
        reply="$HERMES_STEER_REPLY"
      fi
      printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"ses_steer","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"%s\\n"}}}}\n' "$reply"
      printf '{"jsonrpc":"2.0","id":%s,"result":{"stopReason":"end_turn"}}\n' "$id"
      case "$reply" in
        '⏩ Steer queued'*) ;;
        *) continue ;;
      esac
      printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"ses_steer","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"PINEAPPLE"}}}}\n'
      printf '{"jsonrpc":"2.0","id":%s,"result":{"stopReason":"end_turn","usage":{"inputTokens":11,"outputTokens":3}}}\n' "$prompt_id"
      exit 0
      ;;
    *'"method":"session/prompt"'*)
      prompt_id="$id"
      printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"ses_steer","update":{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"working"}}}}\n'
      if [ -z "$HERMES_WAIT_FOR_STEER" ]; then
        printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"ses_steer","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"plain"}}}}\n'
        printf '{"jsonrpc":"2.0","id":%s,"result":{"stopReason":"end_turn"}}\n' "$prompt_id"
        exit 0
      fi
      ;;
  esac
done
`
}

func startHermesSteerSession(t *testing.T, env map[string]string, negotiated, builtin bool) (*Session, context.Context) {
	t.Helper()
	fakePath := filepath.Join(t.TempDir(), "hermes")
	writeTestExecutable(t, fakePath, []byte(fakeHermesSteerACPScript()))
	backend, err := New("hermes", Config{ExecutablePath: fakePath, Env: env, Logger: slog.Default(), BuiltinRuntime: builtin})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	t.Cleanup(cancel)
	session, err := backend.Execute(ctx, "do the task", ExecOptions{Timeout: 20 * time.Second, EnableTaskSupplement: negotiated})
	if err != nil {
		t.Fatal(err)
	}
	return session, ctx
}

func TestHermesSupplementSteersActivePrompt(t *testing.T) {
	t.Parallel()
	requestsPath := filepath.Join(t.TempDir(), "requests.jsonl")
	session, ctx := startHermesSteerSession(t, map[string]string{
		"HERMES_WAIT_FOR_STEER": "1",
		"HERMES_REQUESTS_FILE":  requestsPath,
	}, true, true)
	if session.Supplement == nil || session.SupplementReady == nil {
		t.Fatal("negotiated Hermes session did not expose supplement callbacks")
	}
	waitKiroSupplementReady(t, session)
	messages := drainKiroMessages(session)

	if err := session.Supplement(ctx, "The word is PINEAPPLE."); err != nil {
		t.Fatalf("steer: %v", err)
	}
	result := <-session.Result
	got := <-messages
	if result.Status != "completed" {
		t.Fatalf("turn status=%q error=%q", result.Status, result.Error)
	}
	if result.Output != "PINEAPPLE" {
		t.Fatalf("turn output=%q, want only the steered answer (no steer acknowledgement)", result.Output)
	}
	for _, msg := range got {
		if strings.Contains(msg.Content, "Steer queued") {
			t.Fatalf("steer acknowledgement leaked into the transcript: %+v", msg)
		}
	}
	if len(result.Usage) == 0 {
		t.Fatal("the turn's own usage was lost: the steer response must not stand in for it")
	}
	if session.SupplementReady() {
		t.Fatal("supplement stayed ready after the turn's session/prompt completed")
	}
	if err := session.Supplement(ctx, "too late"); err == nil {
		t.Fatal("supplement after the turn ended must fail, not report delivery")
	}
	requests, err := os.ReadFile(requestsPath)
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{`"text":"/steer The word is PINEAPPLE."`, `"sessionId":"ses_steer"`} {
		if !strings.Contains(string(requests), want) {
			t.Errorf("ACP requests missing %s:\n%s", want, requests)
		}
	}
}

func TestHermesSupplementRequiresSteerAcknowledgement(t *testing.T) {
	t.Parallel()
	session, ctx := startHermesSteerSession(t, map[string]string{
		"HERMES_WAIT_FOR_STEER": "1",
		"HERMES_STEER_REPLY":    "No active turn — queued for the next turn. (1 queued)",
	}, true, true)
	waitKiroSupplementReady(t, session)
	if err := session.Supplement(ctx, "hello"); err == nil {
		t.Fatal("a steer Hermes did not queue for the running turn must not be reported as delivered")
	}
}

func TestHermesSupplementNotExposedWithoutNegotiationOrForCustomRuntime(t *testing.T) {
	t.Parallel()
	for name, tc := range map[string]struct{ negotiated, builtin bool }{
		"not negotiated": {false, true},
		"custom runtime": {true, false},
	} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			session, _ := startHermesSteerSession(t, nil, tc.negotiated, tc.builtin)
			if session.Supplement != nil || session.SupplementReady != nil {
				t.Fatal("supplement callbacks must not be exposed")
			}
			messages := drainKiroMessages(session)
			result := <-session.Result
			<-messages
			if result.Status != "completed" || result.Output != "plain" {
				t.Fatalf("result=%+v, want a normal completed turn", result)
			}
		})
	}
}
