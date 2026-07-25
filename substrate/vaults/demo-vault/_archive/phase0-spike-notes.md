---
doc_id: phase0-spike-notes
title: Phase 0 ingestion spike — working notes (archived)
status: archived
doc_type: explanation
domains: [software-dev, retrieval]
---

# Phase 0 ingestion spike — working notes (archived)

Complete and moved out of the active surface. Archived is complete-plus-filed: still correct,
but not something a default query should surface. It stays retrievable when explicitly asked for.

The Phase 0 spike validated one book end to end through the ingestion pipeline: batched
extraction, a furniture validator that never drops content silently, and glyph-geometry heading
recovery. The chapter-title corruption — well-formed paths naming the wrong chapter — is the
canonical silent-loss failure this project keeps guarding against.
