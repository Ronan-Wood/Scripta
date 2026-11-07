import BlobGc.Model

/-!
# What the planner guarantees

The headline is `never_deletes_a_referenced_blob`. Suppose `gcPlan` returns a plan and a vault is
either inherited by a registered scope or remembered in the ledger without being retired. Then no
note in that vault names any blob the plan removes, and every such note was read whole. `plan_safe`
adds that every blob removed is held and older than seven days.

The guarantees are not vacuous. `plan_removes_what_it_should` is the converse: a plan removes every
held blob that is old and unreferenced. `a_plan_exists` is a concrete world on which the planner
plans a removal.

The refusal theorems give the converse direction for each input the planner must not guess past.
A malformed frontmatter reference, an unreadable note, or a missing inherited vault each yield
`.refuse .incomplete`, and never a plan.
-/

namespace BlobGc

/-- `v` is in `r`'s inheritance chain: `r` itself, or something a vault in the chain inherits
through its manifest. -/
inductive Reach (w : World) (r : VaultId) : VaultId → Prop
  | refl : Reach w r r
  | step {u y : VaultId} {x : Vault} {inh : List VaultId} :
      Reach w r u → w.lookup u = some x → x.manifest = some inh → y ∈ inh → Reach w r y

/-! ## Unfolding a successful plan -/

theorem plan_eq {w : World} {p : Plan} (h : gcPlan w = .plan p) :
    w.registry ≠ [] ∧ complete w = true ∧ absent w = [] ∧ p = planOf w := by
  unfold gcPlan at h
  split at h
  · cases h
  · split at h
    · cases h
    · split at h
      · cases h
      · cases h
        rename_i h1 h2 h3
        refine ⟨?_, ?_, ?_, rfl⟩
        · simpa [List.isEmpty_iff] using h1
        · simpa using h2
        · simpa [List.isEmpty_iff] using h3

theorem complete_parts {w : World} (h : complete w = true) :
    chainOk w w.read = true ∧ ∀ n ∈ w.notesOf w.read, n.bad = false := by
  simp only [complete, Bool.and_eq_true, Bool.not_eq_true', List.any_eq_false] at h
  exact ⟨h.1, fun n hn => by simpa using h.2 n hn⟩

theorem absent_nil {w : World} (h : absent w = []) :
    ∀ v ∈ w.ledger, v ∉ w.retire → v ∈ w.read := by
  intro v hv hr
  rw [absent, List.filter_eq_nil_iff] at h
  have := h v hv
  by_cases hm : v ∈ w.read
  · exact hm
  · exfalso; apply this; simp [hm, hr]

/-! ## The chain check is sufficient -/

theorem chainOk_covers {w : World} {S : List VaultId} (h : chainOk w S = true) :
    ∀ r ∈ w.registry, ∀ v, Reach w r v → v ∈ S := by
  simp only [chainOk, Bool.and_eq_true, List.all_eq_true, List.contains_iff_mem] at h
  obtain ⟨⟨⟨⟨hreg, _⟩, _⟩, hclosed⟩, _⟩ := h
  intro r hr v hv
  induction hv with
  | refl => exact hreg r hr
  | step _ hl hm hy ih =>
      have := hclosed _ ih
      simp only [World.inherits, hl, hm, Option.getD_some] at this
      exact this _ hy

theorem chainOk_present {w : World} {S : List VaultId} (h : chainOk w S = true) :
    ∀ v ∈ S, ∃ x, w.lookup v = some x := by
  simp only [chainOk, Bool.and_eq_true, List.all_eq_true] at h
  intro v hv
  have := h.1.1.2 v hv
  exact Option.isSome_iff_exists.mp this

theorem mem_notesOf {w : World} {S : List VaultId} {v : VaultId} {x : Vault} {n : Note}
    (hv : v ∈ S) (hl : w.lookup v = some x) (hn : n ∈ x.notes) : n ∈ w.notesOf S := by
  simp only [World.notesOf, List.mem_flatMap]
  exact ⟨v, hv, by simpa [hl] using hn⟩

/-! ## Safety -/

/-- A plan's `vaults` holds every vault in a registered chain, and every remembered vault that was
not retired. -/
theorem plan_reads_everything {w : World} {p : Plan} (h : gcPlan w = .plan p) :
    (∀ r ∈ w.registry, ∀ v, Reach w r v → v ∈ p.vaults) ∧
    (∀ v ∈ w.ledger, v ∉ w.retire → v ∈ p.vaults) := by
  obtain ⟨_, hc, ha, rfl⟩ := plan_eq h
  exact ⟨chainOk_covers (complete_parts hc).1, absent_nil ha⟩

/-- **Safety.** A removed blob is held and old, and no note in any vault the plan read names it. -/
theorem plan_safe {w : World} {p : Plan} (h : gcPlan w = .plan p) :
    ∀ c ∈ p.remove,
      (∃ b ∈ w.blobs, b.sha = c ∧ b.mtime + minAge < w.now) ∧
      ∀ v ∈ p.vaults, ∀ x, w.lookup v = some x → ∀ n ∈ x.notes, c ∉ n.refs := by
  obtain ⟨_, _, _, rfl⟩ := plan_eq h
  intro c hc
  simp only [planOf, loose, List.mem_map, List.mem_filter, old, decide_eq_true_eq] at hc
  obtain ⟨b, ⟨⟨hb, hnref⟩, hold⟩, rfl⟩ := hc
  refine ⟨⟨b, hb, rfl, hold⟩, ?_⟩
  intro v hvS x hl n hn href
  have : b.sha ∈ w.refsOf w.read := by
    simp only [World.refsOf, List.mem_flatMap]
    exact ⟨n, mem_notesOf hvS hl hn, href⟩
  simp [this] at hnref

/-- **The headline.** If a vault is in a registered scope's chain, or is remembered and not retired,
then every note in it was read whole and names no blob the plan removes. -/
theorem never_deletes_a_referenced_blob {w : World} {p : Plan} (h : gcPlan w = .plan p)
    {v : VaultId} (hv : (∃ r ∈ w.registry, Reach w r v) ∨ (v ∈ w.ledger ∧ v ∉ w.retire)) :
    ∃ x, w.lookup v = some x ∧ ∀ n ∈ x.notes,
      n.bad = false ∧ ∀ c ∈ p.remove, c ∉ n.refs := by
  obtain ⟨hcov, hled⟩ := plan_reads_everything h
  obtain ⟨_, hcomp, _, hp⟩ := plan_eq h
  obtain ⟨hc, hgood⟩ := complete_parts hcomp
  have hin : v ∈ p.vaults := by
    rcases hv with ⟨r, hr, hreach⟩ | ⟨hl, hret⟩
    · exact hcov r hr v hreach
    · exact hled v hl hret
  have hinS : v ∈ w.read := by rw [hp] at hin; exact hin
  obtain ⟨x, hx⟩ := chainOk_present hc v hinS
  refine ⟨x, hx, fun n hn => ⟨hgood n (mem_notesOf hinS hx hn), fun c hcr => ?_⟩⟩
  exact (plan_safe h c hcr).2 v hin x hx n hn

/-- **Completeness.** A plan removes every held blob that is old and that no note it read names. -/
theorem plan_removes_what_it_should {w : World} {p : Plan} (h : gcPlan w = .plan p) {b : Blob}
    (hb : b ∈ w.blobs) (hold : b.mtime + minAge < w.now) (hfree : b.sha ∉ w.refsOf p.vaults) :
    b.sha ∈ p.remove := by
  obtain ⟨_, _, _, rfl⟩ := plan_eq h
  simp only [planOf] at hfree
  simp only [planOf, loose, old, List.mem_map, List.mem_filter, decide_eq_true_eq]
  exact ⟨b, ⟨⟨hb, by simpa using hfree⟩, hold⟩, rfl⟩

/-- One registered vault, one note naming blob 1, and two old blobs: blob 2 is removed. -/
def w₀ : World where
  now := 10 ^ 7
  defaultRegistry := false
  registry := [0]
  vaults := [{ id := 0, manifest := some [],
               notes := [{ readable := true,
                           fields := [{ key := .source, loc := .front, toks := [.ok 1] }] }] }]
  blobs := [{ sha := 1, mtime := 0 }, { sha := 2, mtime := 0 }]
  tombstones := []
  ledger := []
  retire := []

theorem a_plan_exists :
    (match gcPlan w₀ with
     | .plan p => some (p.remove, p.recent, p.vaults)
     | .refuse _ => none) = some ([2], [], [0]) := by
  rfl

/-! ## Refusals -/

/-- The chain depends on the vaults on disk and nothing else. -/
theorem closure_congr {w w' : World} (h : w.vaults = w'.vaults) :
    ∀ n s, closure w n s = closure w' n s
  | 0, _ => rfl
  | n + 1, s => by
      have hi : w.inherits = w'.inherits := by
        funext v; simp [World.inherits, World.lookup, h]
      have : grow w s = grow w' s := by simp only [grow, hi]
      simp only [closure, this]
      exact closure_congr h n _

private theorem refuse_of_bad {w : World} (hreg : w.registry ≠ [])
    (hbad : chainOk w w.read = true → ∃ n ∈ w.notesOf w.read, n.bad = true) :
    gcPlan w = .refuse .incomplete := by
  have h1 : w.registry.isEmpty = false := by simpa [List.isEmpty_iff] using hreg
  have h2 : complete w = false := by
    by_cases hc : chainOk w w.read = true
    · obtain ⟨n, hn, hb⟩ := hbad hc
      have : (w.notesOf w.read).any Note.bad = true := List.any_eq_true.mpr ⟨n, hn, hb⟩
      simp [complete, this]
    · simp [complete, hc]
  simp [gcPlan, h1, h2]

/-- **Refusal.** A malformed reference in the frontmatter of any note in any registered chain makes
the planner refuse. It never yields a plan. -/
theorem malformed_reference_refuses {w : World} {r v : VaultId} {x : Vault} {n : Note} {f : Field}
    (hr : r ∈ w.registry) (hv : Reach w r v) (hl : w.lookup v = some x) (hn : n ∈ x.notes)
    (hf : f ∈ n.fields) (hm : f.malformed = true) :
    gcPlan w = .refuse .incomplete := by
  apply refuse_of_bad (List.ne_nil_of_mem hr)
  intro hc
  refine ⟨n, mem_notesOf (chainOk_covers hc r hr v hv) hl hn, ?_⟩
  simp only [Note.bad, Bool.or_eq_true, Bool.not_eq_true']
  exact Or.inr (List.any_eq_true.mpr ⟨f, hf, hm⟩)

/-- **Refusal.** So does a note the scan cannot read. -/
theorem unreadable_note_refuses {w : World} {r v : VaultId} {x : Vault} {n : Note}
    (hr : r ∈ w.registry) (hv : Reach w r v) (hl : w.lookup v = some x) (hn : n ∈ x.notes)
    (hu : n.readable = false) :
    gcPlan w = .refuse .incomplete := by
  apply refuse_of_bad (List.ne_nil_of_mem hr)
  intro hc
  exact ⟨n, mem_notesOf (chainOk_covers hc r hr v hv) hl hn, by simp [Note.bad, hu]⟩

/-- **Refusal.** So does an inherited vault that is not there: the moved core-vault case. -/
theorem missing_vault_refuses {w : World} {r v : VaultId}
    (hr : r ∈ w.registry) (hv : Reach w r v) (hl : w.lookup v = none) :
    gcPlan w = .refuse .incomplete := by
  apply refuse_of_bad (List.ne_nil_of_mem hr)
  intro hc
  obtain ⟨x, hx⟩ := chainOk_present hc v (chainOk_covers hc r hr v hv)
  simp [hl] at hx

/-- **Refusal.** With nothing registered there is no plan, whatever the store holds. -/
theorem empty_registry_refuses {w : World} (h : w.registry = []) :
    gcPlan w = .refuse .noVault := by
  simp [gcPlan, h]

/-- Tombstones do not enter the plan: `gc` is not `forget`, and the plan is the same whatever
`forget` recorded. -/
theorem tombstones_irrelevant (w : World) (t : List Sha) :
    gcPlan { w with tombstones := t } = gcPlan w := by
  have hc : ∀ n s, closure { w with tombstones := t } n s = closure w n s :=
    closure_congr rfl
  simp only [gcPlan, complete, chainOk, absent, planOf, loose, old, World.read, World.above,
    World.fuel, World.refsOf, World.notesOf, World.lookup, World.inherits, hc]
  rfl

end BlobGc
