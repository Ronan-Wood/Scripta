---
doc_id: engine-boundary-old
title: The engine boundary — retrieval engine only (SUPERSEDED)
status: superseded
doc_type: decision
superseded_by: engine-boundary-current
domains: [software-dev, architecture]
---

# The engine boundary — retrieval engine only (SUPERSEDED)

Replaced by [[engine-boundary-current]]. Kept in place so the decision history survives; the
engine excludes it from default retrieval but surfaces the supersession link via the note that
replaced it. Do not re-litigate from this note — read the superseding one.

This earlier draft claimed the Python engine was a retrieval engine only and that the app would
never call into it, with the app owning the real retrieval. That had the boundary backwards and
was corrected.
