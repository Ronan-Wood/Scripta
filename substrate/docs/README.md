# Where the specification lives

The structural contract this engine implements — vault tiers, the `.substrate.toml` manifest
format, the spine fields (`status`, `doc_type`, `confidence`, `domains`), inheritance and
supersession semantics — is specified in **Doc 2**, held in `core-vault` under
`00-operator/specs/`. Doc 1 (the substrate model this all serves) sits beside it.

**This repo implements that contract; it does not define it.** The engine is one consumer of the
vault structure. Scripta is another, an editor plugin would be a third, and none of them owns the
spec — which is why it does not live in any one of them.

A clone of this repo is therefore incomplete by design. That is deliberate and stated here rather
than discovered: a contributor should know immediately that the governing document exists elsewhere,
and what it governs. This file is a pointer, never a copy or a summary — a pointer cannot drift out
of agreement with its target, and a summary would.

`PRINCIPLES.md` and `HANDOFF.md` in this repo are about how the engine is built and how it fails.
They are engine documents and stay here.
