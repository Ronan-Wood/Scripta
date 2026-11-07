---
doc_id: engine-boundary-call
title: Call — where the engine boundary sits
class: conversation
status: active
doc_type: reference
confidence: unstated
domains: [software-dev, architecture]
---

# Call — where the engine boundary sits

A synthetic transcript, kept as a source: the decision it led to is
[[engine-boundary-current]]. What is said here is raw material, and some of it was abandoned
before the call ended.

**Speaker A:** My first instinct was that the app owns retrieval and the engine is a library it
links. Every query would go through the app, and other clients would ask the app.

**Speaker B:** Then an editor or a command line has to start the app to ask anything. That puts
the boundary backwards. The engine should sit at the bottom and answer whoever is asking.

**Speaker A:** Fine — the engine is the retrieval brain, and the app is one client of it, a peer
of the others. It asks the engine for passages and renders what comes back.

**Speaker B:** And the engine does not care who is asking. Write that down as the current
boundary and mark the earlier note superseded rather than deleting it.
