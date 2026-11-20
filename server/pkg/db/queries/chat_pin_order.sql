-- name: ReorderPinnedChatSessions :many
-- Restamps pinned_at so the given chats list in the given order (first = top)
-- under the list's `pinned_at DESC`. Stamps step back one millisecond from
-- now(), so a chat pinned afterwards still lands on top. Only the caller's
-- own, still-pinned, active chats in the workspace are touched; updated_at is
-- left alone because order is a preference, not activity.
UPDATE chat_session AS cs
SET pinned_at = now() - ((o.ord - 1)::int * interval '1 millisecond')
FROM unnest(@session_ids::uuid[]) WITH ORDINALITY AS o(id, ord)
WHERE cs.id = o.id
  AND cs.workspace_id = @workspace_id
  AND cs.creator_id = @creator_id
  AND cs.status = 'active'
  AND cs.pinned_at IS NOT NULL
RETURNING cs.*;
