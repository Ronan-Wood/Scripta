---
doc_id: operator-working-cadence
title: Working cadence — audit, review, implement, verify
status: active
doc_type: explanation
domains: [operator, process]
---

# Working cadence — audit, review, implement, verify

The operator runs Claude as a high-trust execution engine on a fixed loop:
audit, then review, then implement, then verify. The loop is load-bearing and must
never collapse into an autonomous fix pipeline that deletes the review step.

## The four beats

Audit is report-only by design. It surveys the code and names findings; it does not
change anything. The operator reads the audit and chooses which findings to act on.

Review is where the operator decides. Nothing is implemented until a finding has been
selected off the audit. "While I'm here" fixes during an implementation pass are refused.

Implement makes exactly the chosen change and nothing else. Backwards-compatibility shims
for unused code and rename residue are removed cleanly rather than left as commented ghosts.

Verify is two stages, always both, in order. A context-rich crosscheck runs first and
auto-applies what clears its bar. A diff-only adversary runs last, sees only the diff,
assumes it is broken, and never auto-applies. One does not substitute for the other.

## Why the split matters

The crosscheck reviewers can rationalise a change using the surrounding code; the adversary
reviewers cannot, because they are handed the diff alone. Running both is how a plausible but
wrong change is caught before it reaches the operator for final review.
