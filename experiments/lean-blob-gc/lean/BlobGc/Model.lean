/-!
# A model of `substrate blobs gc --unreferenced`'s planner

The model is `blob_lifecycle.gc_plan` (substrate, #84) taken as a pure function from a world to
either a refusal or a deletion plan. Everything is abstract: a checksum is a `Nat`, a vault is a
`Nat`, and a note is the list of referencing fields it carries. That leaves out how those fields are
spelled in markdown, which the differential harness covers.
-/

namespace BlobGc

abbrev Sha := Nat
abbrev VaultId := Nat

/-- The three frontmatter keys that name a blob. -/
inductive Key | source | raw | audio
  deriving DecidableEq, Repr

/-- Inside the leading `---` block, or anywhere after it. -/
inductive Loc | front | body
  deriving DecidableEq, Repr

/-- One value under a referencing key.
* `ok c`: the checksum `c`, well formed (64 lowercase hex).
* `upper c`: `c` in uppercase hex.
* `padded c`: `c` with non-hex characters after it.
* `junk`: no checksum at all.
The scan keeps `c` alive for the first three. In frontmatter only `ok` is well formed. -/
inductive Tok
  | ok (c : Sha)
  | upper (c : Sha)
  | padded (c : Sha)
  | junk
  deriving DecidableEq, Repr

structure Field where
  key  : Key
  loc  : Loc
  toks : List Tok
  deriving Repr

structure Note where
  /-- False for a note the scan cannot read: a dangling link, an evicted iCloud stub, an
  unreadable file. -/
  readable : Bool
  fields   : List Field
  deriving Repr

structure Vault where
  id       : VaultId
  /-- `none`: no `.substrate.toml`. That is fine for an inherited root (core-vault), but not for a
  registered project vault. `some inh`: the vaults it inherits. -/
  manifest : Option (List VaultId)
  notes    : List Note
  deriving Repr

structure Blob where
  sha   : Sha
  /-- Seconds. The time the blob was last stored or found present by an ingest. -/
  mtime : Nat
  deriving Repr

structure World where
  now             : Nat
  /-- Whether the scan read the default registry. Only that kind of scan writes the ledger. -/
  defaultRegistry : Bool
  /-- The project vault of each registered scope. -/
  registry        : List VaultId
  /-- The vaults that exist on disk. A vault that is named somewhere but absent here has moved or
  been unmounted. -/
  vaults          : List Vault
  /-- The store's blobs. -/
  blobs           : List Blob
  tombstones      : List Sha
  /-- `vaults.seen`: the vaults earlier complete scans read. -/
  ledger          : List VaultId
  /-- `--retire-vault`. -/
  retire          : List VaultId
  deriving Repr

def minAge : Nat := 7 * 86400

/-! ## References -/

def Tok.refs : Tok → List Sha
  | .ok c => [c]
  | .upper c => [c]
  | .padded c => [c]
  | .junk => []

def Tok.wellFormed : Tok → Bool
  | .ok _ => true
  | _ => false

def Field.refs (f : Field) : List Sha := f.toks.flatMap Tok.refs

/-- A claim inside the frontmatter that is not one checksum, or for `audio_sha256` not a list of
checksums. An empty value claims nothing. -/
def Field.malformed (f : Field) : Bool :=
  f.loc == .front && !f.toks.isEmpty &&
    (f.toks.any (fun t => !t.wellFormed) || (f.key != .audio && f.toks.length > 1))

def Note.refs (n : Note) : List Sha := n.fields.flatMap Field.refs

/-- A note that makes the scan incomplete. -/
def Note.bad (n : Note) : Bool := !n.readable || n.fields.any Field.malformed

/-! ## Vault chains -/

def World.lookup (w : World) (v : VaultId) : Option Vault := w.vaults.find? (·.id == v)

def World.inherits (w : World) (v : VaultId) : List VaultId :=
  match w.lookup v with
  | some x => x.manifest.getD []
  | none => []

def grow (w : World) (s : List VaultId) : List VaultId :=
  s ++ ((s.flatMap w.inherits).filter (fun v => !s.contains v)).eraseDups

/-- `fuel` rounds of following `inherits`. No proof depends on the result being complete:
`chainOk` checks the result is closed, and refuses if it is not. -/
def closure (w : World) : Nat → List VaultId → List VaultId
  | 0, s => s
  | n + 1, s => closure w n (grow w s)

def World.fuel (w : World) : Nat := w.vaults.length + 1

/-- The vaults the scan reads: every registered vault and everything it inherits. -/
def World.read (w : World) : List VaultId := closure w w.fuel w.registry.eraseDups

/-- What `v` inherits, directly or not. -/
def World.above (w : World) (v : VaultId) : List VaultId := closure w w.fuel (w.inherits v)

/-- Strict resolution, as in `vault.resolve_vaults`:
* every registered vault is read, exists and has a manifest;
* every vault read exists, and what it inherits is read too;
* no vault inherits itself. -/
def chainOk (w : World) (S : List VaultId) : Bool :=
  w.registry.all (fun r => S.contains r) &&
  w.registry.all (fun r => match w.lookup r with
                           | some x => x.manifest.isSome
                           | none => false) &&
  S.all (fun v => (w.lookup v).isSome) &&
  S.all (fun v => (w.inherits v).all (fun y => S.contains y)) &&
  S.all (fun v => !(w.above v).contains v)

def World.notesOf (w : World) (S : List VaultId) : List Note :=
  S.flatMap (fun v => match w.lookup v with
                      | some x => x.notes
                      | none => [])

def World.refsOf (w : World) (S : List VaultId) : List Sha :=
  (w.notesOf S).flatMap Note.refs

/-! ## The planner -/

inductive Refusal
  /-- No vault is registered, so every blob would look unreferenced. -/
  | noVault
  /-- A chain could not be resolved strictly, a note could not be read, or a reference in a note's
  frontmatter is malformed. -/
  | incomplete
  /-- A vault in the ledger has dropped out of the registry and was not retired. -/
  | unregistered
  deriving DecidableEq, Repr

structure Plan where
  remove : List Sha
  /-- Unreferenced, but too young to remove. -/
  recent : List Sha
  vaults : List VaultId
  /-- The ledger after planning. -/
  ledger : List VaultId
  deriving Repr

inductive Result
  | refuse (r : Refusal)
  | plan (p : Plan)
  deriving Repr

def old (w : World) (b : Blob) : Bool := decide (b.mtime + minAge < w.now)

/-- The scan is complete: every chain resolves strictly and every note it read was read whole,
with no malformed frontmatter reference. -/
def complete (w : World) : Bool :=
  chainOk w w.read && !(w.notesOf w.read).any Note.bad

/-- Vaults an earlier scan read that this one did not, and that were not retired. -/
def absent (w : World) : List VaultId :=
  w.ledger.filter (fun v => !w.read.contains v && !w.retire.contains v)

def loose (w : World) : List Blob :=
  w.blobs.filter (fun b => !(w.refsOf w.read).contains b.sha)

def planOf (w : World) : Plan where
  remove := ((loose w).filter (fun b => old w b)).map (·.sha)
  recent := ((loose w).filter (fun b => !old w b)).map (·.sha)
  vaults := w.read
  ledger := if w.defaultRegistry then (w.ledger ++ w.read).eraseDups else w.ledger

def gcPlan (w : World) : Result :=
  if w.registry.isEmpty then .refuse .noVault
  else if !complete w then .refuse .incomplete
  else if !(absent w).isEmpty then .refuse .unregistered
  else .plan (planOf w)

end BlobGc
