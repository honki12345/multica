package agent

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// hermesSupplementTimeout bounds one `/steer` round trip. A steer that Hermes
// accepts answers within milliseconds; a slower answer means Hermes ran the
// text as a prompt instead (the turn ended in between), which must not be
// reported as delivered. A var so tests can shorten it.
var hermesSupplementTimeout = 10 * time.Second

// hermesSteerPromptLabel tracks the steer's session/prompt under a different
// pending-RPC label, so its response never feeds extractPromptResult and can
// not stand in for the real turn's stop reason or usage.
const hermesSteerPromptLabel = "session/prompt#steer"

// Hermes answers an accepted `/steer` with this agent message before the
// session/prompt response (acp_adapter/commands.py _cmd_steer and
// acp_adapter/gateway_commands.py _steer both send it).
const hermesSteerQueuedPrefix = "⏩ Steer queued"

// hermesSteerReplyPrefixes are every reply Hermes sends for a `/steer` prompt.
// They belong to the steer exchange, never to the turn's deliverable.
var hermesSteerReplyPrefixes = []string{hermesSteerQueuedPrefix, "⚠️ Steer failed", "No active turn", "Usage: /steer"}

// hermesSupplementSession delivers additional input to a running Hermes turn
// through Hermes' own `/steer` slash command, sent as a second session/prompt
// on the same ACP connection. Hermes queues the text on the live agent and
// injects it after the current tool batch (or before the next model call), so
// the running turn answers it.
//
// Readiness is opened only once the turn has produced activity: before that
// the gateway may not yet hold the admission `/steer` targets, and Hermes would
// run the text as a new prompt instead of steering.
type hermesSupplementSession struct {
	client *hermesClient

	mu        sync.Mutex // serialises send
	sessionID atomic.Value
	inFlight  atomic.Bool // the turn's session/prompt is on the wire
	started   atomic.Bool // the turn produced activity
	awaiting  atomic.Bool // a steer is waiting for Hermes' reply
	ackQueued atomic.Bool // Hermes replied "Steer queued"
	ackOther  atomic.Value
}

func (s *hermesSupplementSession) begin(sessionID string) {
	s.sessionID.Store(sessionID)
	s.started.Store(false)
	s.inFlight.Store(true)
}

func (s *hermesSupplementSession) stop() {
	s.inFlight.Store(false)
	s.started.Store(false)
}

// observeActivity marks the turn live once an update of the current turn
// arrives while its prompt is in flight.
func (s *hermesSupplementSession) observeActivity() {
	if s.inFlight.Load() {
		s.started.Store(true)
	}
}

func (s *hermesSupplementSession) ready() bool {
	id, _ := s.sessionID.Load().(string)
	return s.inFlight.Load() && s.started.Load() && id != ""
}

// acceptUpdate drops Hermes' reply to our own `/steer` prompt so it never
// reaches the transcript or the task's final output, and records whether it
// confirmed the steer.
func (s *hermesSupplementSession) acceptUpdate(updateType string, update json.RawMessage) bool {
	if !s.awaiting.Load() || updateType != "agent_message_chunk" {
		return true
	}
	var msg struct {
		Content struct {
			Text string `json:"text"`
		} `json:"content"`
	}
	if err := json.Unmarshal(update, &msg); err != nil {
		return true
	}
	text := strings.TrimSpace(msg.Content.Text)
	for _, prefix := range hermesSteerReplyPrefixes {
		if strings.HasPrefix(text, prefix) {
			if prefix == hermesSteerQueuedPrefix {
				s.ackQueued.Store(true)
			} else {
				s.ackOther.Store(text)
			}
			return false
		}
	}
	return true
}

func (s *hermesSupplementSession) send(ctx context.Context, text string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.ready() {
		return fmt.Errorf("hermes turn is not running")
	}
	text = strings.TrimSpace(text)
	if text == "" {
		return fmt.Errorf("empty additional input")
	}
	sessionID, _ := s.sessionID.Load().(string)

	s.ackQueued.Store(false)
	s.ackOther.Store("")
	s.awaiting.Store(true)
	defer s.awaiting.Store(false)

	rpcCtx, cancel := context.WithTimeout(ctx, hermesSupplementTimeout)
	defer cancel()
	_, err := s.client.requestTracked(rpcCtx, "session/prompt", hermesSteerPromptLabel, map[string]any{
		"sessionId": sessionID,
		"prompt":    []map[string]any{{"type": "text", "text": "/steer " + text}},
	}, nil)
	if err != nil {
		return fmt.Errorf("hermes /steer failed: %w", err)
	}
	// Hermes sends its reply as a session update before the prompt response,
	// on the same ordered stream, so it has been observed by now.
	if s.ackQueued.Load() {
		return nil
	}
	if other, _ := s.ackOther.Load().(string); other != "" {
		return fmt.Errorf("hermes did not steer the running turn: %s", other)
	}
	return fmt.Errorf("hermes did not confirm the steer")
}
