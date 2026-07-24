---
title: The Go Programming Language Specification
class: reference-versioned
status: active
version: 1.21
domains: [software-dev, languages]
raw: go-spec-1.21.html
raw_location: user-defined
---

# Go language specification (1.21) — source metadata

A versioned reference source. Passages are only true for a stated version, so the class gate
requires a captured version — an unversioned spec passage reads authoritative while being
silently stale. Which version is "current" is not global: a project pins it in `.substrate.toml`
under `[reference_pins]`. This source is version 1.21; a project pinning `go = "1.21"` treats it
as current and any later spec as superseded-for-that-context.
