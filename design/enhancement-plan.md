# libpdx-argv — enhancement plan (post-1.0)

**Repo:** github.com/paideia-os/libpdx-argv
**Current tag:** v1.0.0 (2026-08-22), milestones M1–M5 all closed (#1–#10)
**Author of this pass:** osarch+softarch enhancement audit, 2026-08-25
**Method:** every claim below is grep-verified against real source in this
repo at `ff29e11`. Consumer claims are verified by reading the consumer's
own `src/` and `deps.list` (read-only) in the parallel clones under
`/tmp/pdx-readme-<tool>`.

This document supersedes nothing; it records what 1.0 actually shipped
versus what its own README/`.pdxdoc`/`caps.decl` claim it shipped, and
converts the delta into a bounded issue list.

---

## 1. Current state

Eight source modules, 1849 lines of `.pdx`; eight test modules, 2518
lines; no library dependencies; no capabilities. The public surface is
real and, on the text-CLI side, complete:

| Module | Entry points | State |
|---|---|---|
| `ParsedArgs` | `reset`, `find_flag_by_id` + 13 storage slots + 10 `ERR_*` | implemented |
| `FlagSpec` | `reset`, `register`, `lookup` | implemented |
| `Parser` | `parse_argv` | implemented |
| `Typed` | `parse_int_u64`, `parse_size`, `parse_timespan` | implemented |
| `StdVocab` | `register_all` + 9 ids + 9 `.rodata` names | implemented |
| `SchemaInvoke` | `parse_from_schema_record` | implemented, **unvalidated** (§2.1) |
| `HelpBackend` | `DOC_TOOL_NAME`, `fill_doc_argv` | implemented |
| `SchemaEmit` | `reset`, `register`, `get_count`, `get_name` | implemented |

No `TODO`/`FIXME`/stub markers survive in `src/`. The argv state machine,
the `FlagSpec`-driven arity decision (the cat-M1 fix), the `--` sentinel,
the `=`/`:` separators, the one-per-hyphen short-flag rejection, and the
three typed decoders all do exactly what `design/architecture.md` says.

## 2. API completeness vs. what is claimed

### 2.1 The dual-mode claim is half-delivered

The README's headline is that the library is "dual-mode by design": a
text path (`Parser::parse_argv`) and a semantic-schema path
(`SchemaInvoke::parse_from_schema_record`). Both entry points exist and
both converge on the same `ParsedArgs`. But the two modes are not
delivered to the same standard.

**The text path takes input from the loader-seeded argv the caller
already owns. The schema path takes input from a peer process over a
`KIND_IPC_ENDPOINT`.** That is the library's only untrusted-input
surface, and it is the one that is not validated:

- `src/schema_invoke.pdx:133,154,157,175` gate `record_len`,
  `flag_count` and `pos_count` with **signed** `jl`/`jg`. All three
  fields are u64 read straight off the wire. A `flag_count` with bit 63
  set (e.g. `0xFFFFFFFFFFFFFFFF`) is *not* greater than 32 under a signed
  compare, so it passes the cap at line 154. The subsequent
  `shl rcx, 4` wraps, the body-fits gate at 175 is satisfied by the
  wrapped value, and the positional-array base computed at
  `schema_flag_loop_done` (`r14 = record_ptr + flag_count*16 + 32`)
  lands 16 bytes past `record_ptr` — inside the header — so the
  positional loop reads offsets out of the magic/version qwords and
  hands the consumer wholly attacker-chosen interior pointers.
- Every `name_off` / `value_off` / `pos_off` is trusted without bound.
  `name_ptr = record_ptr + name_off` with no check that `name_off <
  record_len`, and no check that a NUL appears before the record ends.
  `FlagSpec::lookup` then walks that pointer byte-by-byte until it finds
  a NUL — an unbounded read off the end of the frame.

Both gaps were consciously deferred. `design/architecture.md` §10.1
("What the parser does NOT validate at M3-001") and §10.4 both defer
terminator validation to "a M4 test-matrix concern per
`libpdx-argv.M4-001`". **M4 did not deliver it.** The M4 matrix
(`tests/README.md`, 6 `ParseSchemaRecordTests` cases) covers bad magic,
bad version, short header, oversize count and body-fits — every one of
them a *header* case. No case exercises an out-of-range offset or an
unterminated string, and `tests/README.md` "Non-goals at M4-001" does
not list the deferral either, so it simply fell through the crack
between M3 and M4 and shipped in the 1.0 tag.

For a capability-discipline OS whose whole premise is that a tool's
authority is bounded, shipping an unbounded decoder on the IPC path is
the single least defensible thing in this repo. → **ENH-001, ENH-002**

### 2.2 A declared output schema with no encoder

`caps.decl` and `pkgs/mirror.entry` both declare two output schemas, and
`manifest.pdxsig` freezes that declaration into the signed payload:

```
declares_output_schemas:
  - PdxArgvParsed@0.1
  - PdxArgvRecord@0.1
```

`PdxArgvRecord@0.1` is real — `SchemaInvoke` *consumes* it (note: it is
declared as an *output* schema but is in fact this library's *input*
wire form; that is itself a mislabel).

`PdxArgvParsed@0.1` has **no producer anywhere in `src/`**. Grep for it:
it appears only in `caps.decl`, `pkgs/mirror.entry`, `CHANGELOG.md` and
`.plans/`. The README describes it as "emitted when the consumer opts
into `--pdx-schema`", but the only thing `--pdx-schema` does is set the
`emit_schema` u64 (`src/parser.pdx:250`). There is no function a
consumer can call to serialize `ParsedArgs` into that shape. The library
declares, in a signed manifest, a schema it cannot produce. → **ENH-003**

### 2.3 The 50-case test matrix has never been executed

`tests/` is genuine — 50 hand-written cases with a real pass/fail tally
and a real fail-tag encoding. But `tests/smoke_driver.pdx` ends in a
call to a `SysExit::exit` symbol that this repo does not define:
`tests/README.md` §"Running the smoke" states the wiring layer and the
wrapper script "lands with pkg.M4". `tools/build.sh` only assembles each
`.pdx` to an `.o` and counts encoder failures — it never links, never
boots, never reads an exit code.

So the M4-001 deliverable is "the tests themselves + the driver shape",
and every green signal this repo has ever produced is an *assembler*
signal, not a *behaviour* signal. Every correctness claim in §1 above,
including the ones this audit reads as correct, rests on code review
alone. That is the honest status and it should be stated in `STATUS.md`
rather than left implicit. → **ENH-007**

### 2.4 Shipped documentation describes error codes that do not exist

`doc/libpdx-argv.pdxdoc` is what `doc libpdx-argv` renders and it is in
the `ships` set of `pkgs/mirror.entry` — it is a user-facing artifact of
the signed release. Its DIAGNOSTICS section names three constants that
`src/parsed_args.pdx` does not define:

| `.pdxdoc` line | Named constant | Reality |
|---|---|---|
| 144 | `ERR_UNKNOWN_FLAG` | does not exist; unknown flags are silently accepted (§2.5) |
| 88, 148 | `ERR_TYPED_PARSE` | does not exist; `Typed::*` are leaf and never touch `error_code` |
| 149 | `ERR_SCHEMA_RECORD_MALFORMED` | does not exist; the real codes are 7/8/9 |

Line 88 goes further and asserts "Failing decodes set
`ParsedArgs::error_code = ERR_TYPED_PARSE` and leave `flag_values[k]`
pointing at the offending text" — the second half is true by accident,
the first half is false. A consumer that codes its diagnostic table
against the man page gets a table that never fires. → **ENH-005**

### 2.5 Unknown flags are silently accepted

`FlagSpec::lookup` returns `FKIND_UNKNOWN` on a miss and the parser
treats that identically to `FKIND_BOOL`. This was the correct fix for
the cat-M1 blocker (an unregistered `-n` must not swallow `foo.txt`),
but it means there is *no* path by which a typo'd flag is reported.
`rm --recursive-force /tmp/x` parses clean: `--recursive-force` lands as
a boolean nobody dispatches on, `/tmp/x` lands as a positional, and the
tool proceeds with its default behaviour. In a capability OS the failure
mode of "the flag you thought you passed did nothing" is materially
worse than in POSIX, because the flag the user reached for is frequently
the *restricting* one (`--dry-run`, `--no-cap:`).

The library should keep permissive-by-default (it is a real dependency
of the cat fix) but offer the strict mode its own man page already
documents. → **ENH-004**

### 2.6 Typed flags consume the next token unconditionally

`src/parser.pdx:205` (long) and `:283` (short) consume `argv[i+1]` as
the value of any non-BOOL flag with no leading-byte guard. M1's state
machine (`design/architecture.md` §4) required `argv[i+1][0] != '-'`;
M2 dropped that guard when arity moved to `FlagSpec`. Consequences with
the *standard* vocabulary, which registers `--color` as `FKIND_ENUM` and
`--no-cap` as `FKIND_STR`:

- `ls --color --json` → `--json` is swallowed as the colour mode; the
  `--json` flag is never seen.
- `ls --color file.txt` → the positional is swallowed; `pos_count == 0`.

I3 spells both flags with a mandatory separator (`--color=`, `--no-cap:`),
so the lookahead form should not be accepted for them at all. This wants
a per-registration arity policy, not a global rule change. → **ENH-010**

### 2.7 Smaller gaps

- **Duplicate flags have no defined policy.** `find_flag_by_id` returns
  the *first* match, so `--color=auto --color=never` resolves to `auto`.
  Every mainstream CLI is last-wins. Neither README, `.pdxdoc` nor
  `architecture.md` states a policy. → **ENH-008**
- **Typed decoders wrap silently on overflow.** `parse_int_u64` accepts
  any digit run and returns `ok=1` with a wrapped accumulator;
  `parse_size` shifts past bit 63 the same way. The header comment calls
  this "a non-issue at M2", which is defensible for `-n 5` and not
  defensible for `rm --older-than <wrapped>`. → **ENH-009**
- **Stale prose.** `design/architecture.md` §3 and
  `src/parsed_args.pdx:32` both promise that M4 migrates `ParsedArgs` to
  a caller-owned variant. M4 did not; `tests/README.md` and §11.5
  correctly call it "a post-M5 concern". Two of this repo's own
  documents contradict each other. → folded into **ENH-006**

---

## 3. The org-wide adoption gap, and whose problem it is

### 3.1 What is actually true today

Verified by grepping each tool's own `src/` for a call into this
library's symbols (`parse_argv`, `parsed_args_reset`, `register_all`,
`parse_from_schema_record`, `fill_doc_argv`) and by reading each tool's
`deps.list`:

| Tool | Calls into libpdx-argv? | Evidence | `deps.list` records it? |
|---|:--:|---|:--:|
| `cp` | **yes** | `src/main.pdx:125` `call register_all`, `:141` `call parse_argv` | no (empty) |
| `ls` | **yes** | `src/argv_surface.pdx:223,228` | no (empty) |
| `mkdir` | **yes** | `src/mkdir.pdx:1210` `call parse_argv` | **yes** |
| `mv` | **yes** | `src/argv.pdx:194` `call parse_argv` | **yes** |
| `pkg` | **yes** | `src/main.pdx:103` `call parse_argv` | no (empty) |
| `rm` | **yes** | `src/main.pdx:130` `call parse_argv` | no (empty) |
| `cat` | no | own `CatDispatch::cat_parse_argv`, `src/argv_dispatch.pdx:189` | n/a |
| `doc` | no | own inline argv scan, `src/argv_dispatch.pdx:206` | n/a |
| `shell` | no | own `Pds`, README: "`Pds` mirrors its `ParsedArgs` singleton discipline" | n/a |

**6 of 9 genuinely link and call this library.** Not 9, and not 2.

### 3.2 This repo's own claims are wrong in both directions

- `CHANGELOG.md:62` — the signed 1.0 entry — claims "Consumers (direct):
  `pkg`, `shell`, `doc`, `ls`, `cat`, `cp`, `mv`, `rm`, `mkdir` (all
  nine R49+R50 P0 tools)". Three of those nine do not call it. That is
  an overclaim inside a release artifact.
- `README.md` "Callers" swings the other way: it lists only `pkg` and
  `ls` as verified, correctly flags `cat` as a non-caller, and files
  `cp`, `mkdir`, `mv`, `rm` under "likely callers … not verified here"
  when all four demonstrably are, while listing `doc` and `shell` in the
  same bucket when neither is.

Fixing both is cheap and is squarely this repo's job. → **ENH-011**

### 3.3 Diagnosis: the gap is not library-side friction

Taking the three non-consumers one at a time:

- **`cat`** — the migration is *scheduled*, not blocked. cat's own
  source and this repo's README agree that cat's argv surface moves to
  libpdx-argv at `cat.M3`, deliberately held off M2 to preserve
  byte-compat with the M1 golden fixtures. Ordinary release sequencing;
  nothing about the API is in the way. **Tool-side, by plan.**
- **`doc`** — `doc/src/argv_dispatch.pdx:11` says in its own words
  "M1: inline positional; M2: libpdx-argv". doc parses one positional
  today and has already committed to the migration. **Tool-side, by
  plan.**
- **`shell`** — the only case with a real library-side cause. A shell
  parses many command lines per process; `ParsedArgs`, `FlagSpec` and
  `SchemaEmit` are all `.bss` singletons with one live parse context per
  process (`design/architecture.md` §3). shell could not adopt the
  library as shipped even if it wanted to, so it built `Pds` — which its
  README describes as *mirroring* `ParsedArgs`' discipline, i.e. a
  reimplementation forced by storage model, not a rejection of the
  design. The caller-owned context that would have unblocked it is
  exactly the thing §3 of `architecture.md` promised for M4 and never
  delivered.

  Even so, note the honest counter-argument: a shell tokenizes a command
  *language* (quoting, pipelines, redirections, history expansion), not
  its own flag surface. `Pds` would probably still exist. The
  caller-owned context is worth building because *multi-parse* is a real
  and recurring need — subshells, `mux` splits, `pkg`'s subcommand
  re-parse — not because it will necessarily convert shell.

**Verdict: the adoption gap is ~85% tool-side scheduling and ~15%
library-side storage-model friction.** There is no evidence of API
awkwardness, doc-quality-driven avoidance, or a missing feature that
drove a tool away — the six adopters wired it in a handful of lines
each, which is the strongest available signal that the API is fit for
purpose. Accordingly this plan files exactly **one** adoption-oriented
issue (ENH-006, the caller-owned context) and does not manufacture
"make X easier to adopt" work. The `cat`, `doc` and (mostly) `shell`
gaps belong on the tool side and should be tracked in those repos.

### 3.4 Noted for the paideia-os monorepo (not filed here)

Four tools — `cp`, `ls`, `pkg`, `rm` — call into libpdx-argv while
shipping an empty `deps.list`. `pkg install --strict` verifies a
package's dependency set against exactly that file, so four P0 tools
will link a library their manifest does not declare. This is a per-tool
defect (and possibly a `deps.list`-lint gap in `pkg`), not a
libpdx-argv defect; it is recorded here only so the org-wide audit sees
it. **No issue filed in this repo.**

---

## 4. Issue plan

Milestone: **Enhancement v1.1 — libpdx-argv** (milestone 6), filed
2026-08-25 as issues #11–#21.

| ID | Issue | Title | Effort | Deps |
|---|---|---|:--:|---|
| ENH-001 | #12 | SchemaInvoke: bounds-validate wire offsets + string terminators | M | #11 |
| ENH-002 | #11 | SchemaInvoke: unsigned compares on wire-supplied counts and record_len | S | none |
| ENH-003 | #13 | PdxArgvParsed@0.1: implement the encoder or withdraw the declaration | M | none |
| ENH-004 | #15 | Opt-in strict mode: ERR_UNKNOWN_FLAG for unregistered flags | M | none |
| ENH-005 | #16 | .pdxdoc DIAGNOSTICS: remove three non-existent error codes | S | #15 |
| ENH-006 | #17 | Caller-owned ParsedArgs context (multi-parse) | L | #14 |
| ENH-007 | #14 | Runnable smoke: SysExit wiring + tools/run-tests.sh | M | none |
| ENH-008 | #18 | Define and implement duplicate-flag policy (last-wins) | S | none |
| ENH-009 | #19 | Typed decoders: detect overflow instead of wrapping silently | S | #14 |
| ENH-010 | #20 | Per-registration arity policy: separator-required typed flags | M | #14 |
| ENH-011 | #21 | Consumer-accuracy pass: README Callers + CHANGELOG overclaim | XS | none |

Suggested order: #11 → #12 (the security pair, both cheap and both on
the untrusted path) → #14 (so everything after it can be *tested*
rather than reviewed) → #21, #16 (documentation truth, near-zero cost)
→ #15, #18, #19, #20 (semantics) → #13, #17 (the two that touch the
wire contract and the storage model, and therefore want a 1.1 or 2.0
boundary decision first).

Nothing here is an API break except ENH-006, which is additive if the
singleton entry points are retained as thin wrappers over a
library-owned default context.

---

## 5. Is v1.0.0 defensible?

**On the text-CLI half: yes.** `Parser::parse_argv`, `FlagSpec`,
`StdVocab`, `Typed` and `HelpBackend` are complete, internally
consistent with `design/architecture.md`, free of stubs, and — the
strongest evidence available — wired into six independent tools by
their own authors without a single reported API complaint. The D3
grammar contract is implemented exactly as specified, including the
deliberate POSIX break.

**On the semantic-schema half: no.** The mode the README leads with is
half-shipped: the decoder performs no validation on its only untrusted
input (§2.1), and the companion output schema the signed manifest
declares has no encoder at all (§2.2). Signing a manifest that declares
`PdxArgvParsed@0.1` is a claim the code does not honour.

**Overall:** the tag is defensible as a *source-frozen milestone* — the
tree is coherent, the milestone rollup is honest about M1–M5 scope, and
the PENDING signature sentinels are correctly formed. It is **not**
defensible as a 1.0 *stability promise* for the semantic-pipe path,
because that path's contract is not enforced and its test matrix has
never run (§2.3). The proportionate response is not to retract the tag:
it is to land ENH-002/001/007/003 and cut **1.1 as the first tag whose
claims are all mechanically verified**, and to say plainly in `STATUS.md`
that 1.0's green signal is an assembler signal.
