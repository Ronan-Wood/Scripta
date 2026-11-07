import BlobGc
import Lean.Data.Json

/-!
The model as a process. It reads one JSON world per line on stdin and writes one JSON result per
line on stdout. The harness keeps it running for the whole differential run.

The input format is the one `harness/world.py` writes (`World.to_json`). The output is
`{"refuse": "noVault" | "incomplete" | "unregistered"}` or
`{"remove": [...], "recent": [...], "vaults": [...], "ledger": [...]}`.
-/

open Lean BlobGc

def field (j : Json) (k : String) : Except String Json := j.getObjVal? k

def nats (j : Json) (k : String) : Except String (List Nat) := do
  let a ← (← field j k).getArr?
  a.toList.mapM (·.getNat?)

def key : String → Except String Key
  | "source" => pure .source
  | "raw" => pure .raw
  | "audio" => pure .audio
  | s => throw s!"key {s}"

def loc : String → Except String Loc
  | "front" => pure .front
  | "body" => pure .body
  | s => throw s!"loc {s}"

def tok (j : Json) : Except String Tok := do
  let a := (← j.getArr?).toList
  match a with
  | [k] => if (← k.getStr?) == "junk" then pure .junk else throw "tok"
  | [k, c] =>
      let c ← c.getNat?
      match ← k.getStr? with
      | "ok" => pure (.ok c)
      | "upper" => pure (.upper c)
      | "padded" => pure (.padded c)
      | s => throw s!"tok {s}"
  | _ => throw "tok shape"

def fieldOf (j : Json) : Except String Field := do
  pure { key := ← key (← (← field j "key").getStr?)
         loc := ← loc (← (← field j "loc").getStr?)
         toks := ← (← (← field j "toks").getArr?).toList.mapM tok }

def noteOf (j : Json) : Except String Note := do
  pure { readable := ← (← field j "readable").getBool?
         fields := ← (← (← field j "fields").getArr?).toList.mapM fieldOf }

def vaultOf (j : Json) : Except String Vault := do
  let m ← field j "manifest"
  let manifest ← if m.isNull then pure none else
    some <$> (← m.getArr?).toList.mapM (·.getNat?)
  pure { id := ← (← field j "id").getNat?
         manifest
         notes := ← (← (← field j "notes").getArr?).toList.mapM noteOf }

def blobOf (j : Json) : Except String Blob := do
  match (← j.getArr?).toList with
  | [s, m] => pure { sha := ← s.getNat?, mtime := ← m.getNat? }
  | _ => throw "blob shape"

def worldOf (j : Json) : Except String World := do
  pure { now := ← (← field j "now").getNat?
         defaultRegistry := ← (← field j "default").getBool?
         registry := ← nats j "registry"
         vaults := ← (← (← field j "vaults").getArr?).toList.mapM vaultOf
         blobs := ← (← (← field j "blobs").getArr?).toList.mapM blobOf
         tombstones := ← nats j "tombstones"
         ledger := ← nats j "ledger"
         retire := ← nats j "retire" }

def arr (l : List Nat) : Json := Json.arr (l.map (fun n : Nat => toJson n)).toArray

def resultJson : Result → Json
  | .refuse r => Json.mkObj [("refuse", Json.str (match r with
      | .noVault => "noVault" | .incomplete => "incomplete" | .unregistered => "unregistered"))]
  | .plan p => Json.mkObj [("remove", arr p.remove), ("recent", arr p.recent),
      ("vaults", arr p.vaults), ("ledger", arr p.ledger)]

partial def loop (stdin : IO.FS.Stream) (stdout : IO.FS.Stream) : IO Unit := do
  let line ← stdin.getLine
  if line.isEmpty then return
  let out := match Json.parse line >>= worldOf with
    | .ok w => resultJson (gcPlan w)
    | .error e => Json.mkObj [("error", Json.str e)]
  stdout.putStrLn out.compress
  stdout.flush
  loop stdin stdout

def main : IO Unit := do
  loop (← IO.getStdin) (← IO.getStdout)
