---
doc_id: manifest-inheritance
title: Manifest inheritance composes core into project scope
status: complete
doc_type: explanation
domains: [software-dev, retrieval]
---

# Manifest inheritance composes core into project scope

Complete, done and correct — kept on the active retrieval surface because complete is not the
same as superseded. A project vault carries a root manifest that names which vaults to load.
The engine reads it, resolves what it inherits, and indexes the union as one retrieval scope.

Under Option A this is nothing more than "which source paths to index": no copies, no submodules,
no synchronisation. Aim the engine at a project vault and a query reaches both the project's own
notes and everything the project inherits from core.
