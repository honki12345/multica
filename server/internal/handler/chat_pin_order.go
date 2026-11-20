package handler

import (
	"encoding/json"
	"net/http"

	"github.com/jackc/pgx/v5/pgtype"
	db "github.com/multica-ai/multica/server/pkg/db/generated"
	"github.com/multica-ai/multica/server/pkg/protocol"
)

type ReorderPinnedChatSessionsRequest struct {
	// SessionIDs is every pinned chat in the caller's list, top first.
	SessionIDs []string `json:"session_ids"`
}

// ReorderPinnedChatSessions saves the order the caller dragged their pinned
// chats into. The body must name exactly the pinned chats the caller's list
// shows: a missing, extra, unpinned or foreign id means the client's view is
// stale, so nothing is written and the client reloads (409). The order is
// stored by restamping pinned_at, which the list already sorts by. A chat
// pinned while this runs is not in the body and keeps its own, newer stamp,
// so it stays on top, as any new pin does.
func (h *Handler) ReorderPinnedChatSessions(w http.ResponseWriter, r *http.Request) {
	userID, ok := requireUserID(w, r)
	if !ok {
		return
	}
	workspaceID := ctxWorkspaceID(r.Context())

	var req ReorderPinnedChatSessionsRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	if len(req.SessionIDs) == 0 {
		writeError(w, http.StatusBadRequest, "session_ids is required")
		return
	}
	ids, ok := parseUUIDSliceOrBadRequest(w, req.SessionIDs, "session_ids")
	if !ok {
		return
	}
	requested := make(map[pgtype.UUID]struct{}, len(ids))
	for _, id := range ids {
		if _, dup := requested[id]; dup {
			writeError(w, http.StatusBadRequest, "duplicate chat session id")
			return
		}
		requested[id] = struct{}{}
	}

	member, ok := h.workspaceMember(w, r, workspaceID)
	if !ok {
		return
	}
	actorType, actorID := h.resolveActor(r, userID, workspaceID)
	allowed, ok := h.accessibleAgentIDs(r.Context(), workspaceID, actorType, actorID, member.Role)
	if !ok {
		writeError(w, http.StatusInternalServerError, "failed to resolve agent access")
		return
	}

	tx, err := h.TxStarter.Begin(r.Context())
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to start transaction")
		return
	}
	defer tx.Rollback(r.Context())
	qtx := h.Queries.WithTx(tx)

	// The pinned set the caller's list shows: same query and agent filter as
	// ListChatSessions, so a pinned chat hidden from the list never makes a
	// reorder impossible.
	rows, err := qtx.ListChatSessionsByCreator(r.Context(), db.ListChatSessionsByCreatorParams{
		WorkspaceID: parseUUID(workspaceID),
		CreatorID:   parseUUID(userID),
	})
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to list chat sessions")
		return
	}
	pinned := 0
	for _, s := range rows {
		if !s.PinnedAt.Valid {
			continue
		}
		if _, ok := allowed[uuidToString(s.AgentID)]; !ok {
			continue
		}
		if _, ok := requested[s.ID]; !ok {
			writeError(w, http.StatusConflict, "pinned chats changed; reload and try again")
			return
		}
		pinned++
	}
	if pinned != len(ids) {
		writeError(w, http.StatusConflict, "pinned chats changed; reload and try again")
		return
	}

	updated, err := qtx.ReorderPinnedChatSessions(r.Context(), db.ReorderPinnedChatSessionsParams{
		WorkspaceID: parseUUID(workspaceID),
		CreatorID:   parseUUID(userID),
		SessionIds:  ids,
	})
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to reorder pinned chats")
		return
	}
	// An unpin that committed after the read above leaves a row out.
	if len(updated) != len(ids) {
		writeError(w, http.StatusConflict, "pinned chats changed; reload and try again")
		return
	}
	if err := tx.Commit(r.Context()); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to reorder pinned chats")
		return
	}

	// No `pinned` in these events: one delivered after a later unpin must not
	// pin the chat again on another device. A pin time on an unpinned row is
	// ignored by the list order.
	for _, s := range updated {
		sessionID := uuidToString(s.ID)
		h.publishChat(protocol.EventChatSessionUpdated, workspaceID, "member", userID, sessionID, protocol.ChatSessionUpdatedPayload{
			ChatSessionID: sessionID,
			Title:         s.Title,
			PinnedAt:      timestampToNanoPtr(s.PinnedAt),
			UpdatedAt:     timestampToString(s.UpdatedAt),
		})
	}

	w.WriteHeader(http.StatusNoContent)
}
