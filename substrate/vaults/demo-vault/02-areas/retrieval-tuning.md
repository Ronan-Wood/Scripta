---
doc_id: retrieval-tuning
title: Retrieval tuning — the model axis is exhausted
status: active
doc_type: explanation
domains: [software-dev, retrieval]
---

# Retrieval tuning — the model axis is exhausted

Active work thread. Five embedders, four reranking strategies, and four generators were swept
against the gold set. Everything ties the configuration found before any of them, so the
remaining gains are structural, not model choice.

The reranker behaves as an equaliser: it halves the spread between embedders and allocates its
gain inversely to embedder quality, giving the most help to the weakest embedder. The practical
consequence is to pick the cheapest adequate embedder and let the reranker close the gap.
