---
doc_id: engine-boundary-current
title: The engine boundary — the Python engine powers the app
status: active
doc_type: decision
supersedes: engine-boundary-old
domains: [software-dev, architecture]
---

# The engine boundary — the Python engine powers the app

Current, correct statement of the engine/app boundary. This note supersedes the earlier one,
which had the boundary backwards; the history is why the question is not re-litigated.

The Python engine IS the retrieval brain, and it sits at the bottom. The app is a client that
asks the engine to find the relevant passages and gets back a structured result. Other clients —
an editor, a command line, an orchestration layer — are peers of the app, all speaking to the
same engine. The engine does not care who is asking.
