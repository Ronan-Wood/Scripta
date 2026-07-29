# Where the specification lives

The structural contract this engine implements — vault tiers, the `.substrate.toml` manifest
format, the spine fields (`status`, `doc_type`, `confidence`, `domains`), inheritance and
supersession semantics — is specified in **Doc 2**, held in `core-vault` under
`00-operator/specs/`. Doc 1 (the substrate model this all serves) sits beside it.

**This repo implements that contract; it does not define it.** The engine is one consumer of the
vault structure. Scripta is another, an editor plugin would be a third, and none of them owns the
spec — which is why it does not live in any one of them.

**Doc 3a — the MCP server surface — lives somewhere else again, and the split is the point.**
It is `03-references/doc3a-mcp-server.md` in the **scripta PROJECT vault**, not core-vault. Docs 1
and 2 are shared contracts that several consumers implement and none owns, so they sit in the tier
every scope inherits. Doc 3a describes one product's transport and changes when that product
changes, so it belongs with the project it governs. Reach it with
`substrate query --scope scripta`, or read the file.

That it is written down at all is recent. **Until 2026-07-29 Doc 3a existed on no disk**, while
nine files in this repo cited it 22 times — including two verbatim quotations in test docstrings.
Every citation turned out to be accurate, which is the lucky version of that story rather than the
expected one. Four spec/implementation divergences were found on recovery and are marked inline in
the note rather than silently reconciled.

A clone of this repo is therefore incomplete by design. That is deliberate and stated here rather
than discovered: a contributor should know immediately that the governing document exists elsewhere,
and what it governs. This file is a pointer, never a copy or a summary — a pointer cannot drift out
of agreement with its target, and a summary would.

`PRINCIPLES.md` and `HANDOFF.md` in this repo are about how the engine is built and how it fails.
They are engine documents and stay here.
