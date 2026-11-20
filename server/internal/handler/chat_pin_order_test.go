package handler

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func pinTestChat(t *testing.T, sessionID string) {
	t.Helper()
	if _, err := testPool.Exec(context.Background(),
		`UPDATE chat_session SET pinned_at = now() WHERE id = $1`, sessionID); err != nil {
		t.Fatalf("pin chat: %v", err)
	}
}

// pinnedChatIDsInListOrder reads the caller's chat list through the handler
// and returns the pinned ids in the order the list shows them.
func pinnedChatIDsInListOrder(t *testing.T) ([]string, map[string]ChatSessionResponse) {
	t.Helper()
	w := httptest.NewRecorder()
	testHandler.ListChatSessions(w, withChatTestWorkspaceCtx(t, newRequest(http.MethodGet, "/api/chat/sessions", nil)))
	if w.Code != http.StatusOK {
		t.Fatalf("ListChatSessions: %d %s", w.Code, w.Body.String())
	}
	var list []ChatSessionResponse
	if err := json.Unmarshal(w.Body.Bytes(), &list); err != nil {
		t.Fatalf("decode list: %v", err)
	}
	var ids []string
	byID := map[string]ChatSessionResponse{}
	for _, s := range list {
		if s.Pinned {
			ids = append(ids, s.ID)
			byID[s.ID] = s
		}
	}
	return ids, byID
}

func reorderPinnedChats(t *testing.T, ids []string) *httptest.ResponseRecorder {
	t.Helper()
	req := withChatTestWorkspaceCtx(t, newRequest(http.MethodPut, "/api/chat/sessions/pin-order", map[string]any{
		"session_ids": ids,
	}))
	w := httptest.NewRecorder()
	testHandler.ReorderPinnedChatSessions(w, req)
	return w
}

func TestReorderPinnedChatSessions_SavesOrderWithoutTouchingActivity(t *testing.T) {
	agentID := createHandlerTestAgent(t, "ChatPinOrderAgent", []byte("[]"))
	a := createHandlerTestChatSession(t, agentID)
	b := createHandlerTestChatSession(t, agentID)
	c := createHandlerTestChatSession(t, agentID)
	for _, id := range []string{a, b, c} {
		pinTestChat(t, id)
	}

	var updatedBefore time.Time
	if err := testPool.QueryRow(context.Background(),
		`SELECT updated_at FROM chat_session WHERE id = $1`, b).Scan(&updatedBefore); err != nil {
		t.Fatalf("read updated_at: %v", err)
	}

	before, _ := pinnedChatIDsInListOrder(t)
	// Move c to the top and a to the bottom; keep any other pinned chats
	// the shared test user already has in the order the list shows them.
	want := []string{c, b}
	for _, id := range before {
		if id != a && id != b && id != c {
			want = append(want, id)
		}
	}
	want = append(want, a)

	if w := reorderPinnedChats(t, want); w.Code != http.StatusNoContent {
		t.Fatalf("reorder: want 204, got %d %s", w.Code, w.Body.String())
	}

	got, byID := pinnedChatIDsInListOrder(t)
	if len(got) != len(want) {
		t.Fatalf("pinned list after reorder: want %v, got %v", want, got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("pinned list after reorder: want %v, got %v", want, got)
		}
	}
	if byID[c].PinnedAt == nil || byID[a].PinnedAt == nil || *byID[c].PinnedAt <= *byID[a].PinnedAt {
		t.Fatalf("pinned_at must descend with the order: top %v, bottom %v", byID[c].PinnedAt, byID[a].PinnedAt)
	}

	var updatedAfter time.Time
	if err := testPool.QueryRow(context.Background(),
		`SELECT updated_at FROM chat_session WHERE id = $1`, b).Scan(&updatedAfter); err != nil {
		t.Fatalf("read updated_at: %v", err)
	}
	if !updatedAfter.Equal(updatedBefore) {
		t.Fatalf("reorder must not touch updated_at: before %v, after %v", updatedBefore, updatedAfter)
	}

	// A chat pinned after a reorder still goes on top.
	d := createHandlerTestChatSession(t, agentID)
	pinReq := withURLParam(withChatTestWorkspaceCtx(t, newRequest(http.MethodPatch, "/api/chat/sessions/"+d+"/pin", map[string]any{"pinned": true})), "sessionId", d)
	pinW := httptest.NewRecorder()
	testHandler.SetChatSessionPinned(pinW, pinReq)
	if pinW.Code != http.StatusOK {
		t.Fatalf("pin d: %d %s", pinW.Code, pinW.Body.String())
	}
	if got, _ := pinnedChatIDsInListOrder(t); got[0] != d {
		t.Fatalf("newly pinned chat should be first, got %v", got)
	}
}

func TestReorderPinnedChatSessions_RejectsAStaleOrForeignList(t *testing.T) {
	ctx := context.Background()
	agentID := createHandlerTestAgent(t, "ChatPinOrderRejectAgent", []byte("[]"))
	a := createHandlerTestChatSession(t, agentID)
	b := createHandlerTestChatSession(t, agentID)
	unpinned := createHandlerTestChatSession(t, agentID)
	pinTestChat(t, a)
	pinTestChat(t, b)

	var otherUserID string
	if err := testPool.QueryRow(ctx, `
		INSERT INTO "user" (name, email) VALUES ('Pin Order Other', 'pin-order-other@multica.test')
		RETURNING id
	`).Scan(&otherUserID); err != nil {
		t.Fatalf("create other user: %v", err)
	}
	t.Cleanup(func() {
		testPool.Exec(context.Background(), `DELETE FROM "user" WHERE id = $1`, otherUserID)
	})
	var foreign string
	if err := testPool.QueryRow(ctx, `
		INSERT INTO chat_session (workspace_id, agent_id, creator_id, title, status, explicitly_created_at, pinned_at)
		VALUES ($1, $2, $3, 'Someone else''s chat', 'active', now(), now())
		RETURNING id
	`, testWorkspaceID, agentID, otherUserID).Scan(&foreign); err != nil {
		t.Fatalf("create foreign chat: %v", err)
	}
	t.Cleanup(func() {
		testPool.Exec(context.Background(), `DELETE FROM chat_session WHERE id = $1`, foreign)
	})

	current, _ := pinnedChatIDsInListOrder(t)
	without := func(drop string) []string {
		var out []string
		for _, id := range current {
			if id != drop {
				out = append(out, id)
			}
		}
		return out
	}

	cases := []struct {
		name string
		ids  []string
		want int
	}{
		{"another user's chat", append(append([]string{}, current...), foreign), http.StatusConflict},
		{"a chat that is not pinned", append(append([]string{}, current...), unpinned), http.StatusConflict},
		{"a pinned chat left out", without(a), http.StatusConflict},
		{"the same chat twice", append(append([]string{}, current...), b), http.StatusBadRequest},
		{"an id that is not a uuid", append(append([]string{}, current...), "not-a-uuid"), http.StatusBadRequest},
		{"an empty list", []string{}, http.StatusBadRequest},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if w := reorderPinnedChats(t, tc.ids); w.Code != tc.want {
				t.Fatalf("want %d, got %d %s", tc.want, w.Code, w.Body.String())
			}
			after, _ := pinnedChatIDsInListOrder(t)
			if len(after) != len(current) {
				t.Fatalf("rejected reorder changed the pinned list: before %v, after %v", current, after)
			}
			for i := range current {
				if after[i] != current[i] {
					t.Fatalf("rejected reorder changed the order: before %v, after %v", current, after)
				}
			}
		})
	}

	var foreignPinned *time.Time
	if err := testPool.QueryRow(ctx, `SELECT pinned_at FROM chat_session WHERE id = $1`, foreign).Scan(&foreignPinned); err != nil {
		t.Fatalf("read foreign pinned_at: %v", err)
	}
	if foreignPinned == nil {
		t.Fatalf("foreign chat lost its pin")
	}
}
