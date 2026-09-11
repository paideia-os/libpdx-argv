# libpdx-argv — architecture

**Wave:** R49 shared library
**Repo:** github.com/paideia-os/libpdx-argv
**Upstream design:** `design/tooling/r49-r50-plan.md` §3.3 and §5.12 in
[paideia-os](https://github.com/paideia-os/paideia-os).

This document describes the internal shape of libpdx-argv. It does not
repeat the wave-level rationale from the paideia-os plan doc; read that
first for the D3 flag-grammar contract (long primary, short one-per-hyphen)
and for why libpdx-argv is a shared library rather than per-tool code.

## 1. Public surface

libpdx-argv exposes two modules to its consumers:

- `ParsedArgs` (`src/parsed_args.pdx`) — the in-memory record every
  consumer reads after `parse_argv` returns. Error-code constants live
  here so callers can distinguish "unknown flag form" from
  "clustered short flag" without pattern-matching on messages.
- `Parser` (`src/parser.pdx`) — two entry points:
  `parse_argv(argv_ptr: u64, argc: u64) -> u64` (the primitive) and
  `parse_argv_skipping_zero(argv_ptr: u64, argc: u64) -> u64`
  (`libpdx-argv.ENH-031`; a thin wrapper that drops `argv[0]` — the
  program-name slot every `_start` receives per the frozen execve ABI
  — before invoking `parse_argv`, see §4).

The consumer wires libpdx-argv into its own tool as follows:

```
parsed_args_reset()                                        // ENH-030 v1.1.0
let err = parse_argv(argv, argc)
if err != ParsedArgs::ERR_OK { emit stderr diagnostic + exit code per I4 }
// walk ParsedArgs::flag_names / flag_values / pos_ptrs to dispatch
```

The consumer never allocates a ParsedArgs itself in M1 — the singleton
lives in libpdx-argv's `.bss` (see §3 below). M4 introduces a
caller-owned struct variant so multiple parse contexts can coexist inside
one process; M1 does not need that shape.

## 2. ParsedArgs record shape

Bootstrap-scope layout (M1). All slots are 8-byte aligned; a slot count of
32 flags + 32 positionals fits every P0 tool's actual invocation surface
by wide margin (the largest observed CLI has 12 flags + 4 positionals for
`pkg install --dry-run --json ...`).

| slot           | type       | width  | meaning                                          |
|----------------|------------|--------|--------------------------------------------------|
| `flag_names`   | `[u64;32]` | 256 B  | pointer per `--flag`; NUL-terminated in argv     |
| `flag_values`  | `[u64;32]` | 256 B  | pointer per `--flag`; 0 iff flag is boolean      |
| `flag_count`   | `u64`      |   8 B  | # of `--flag` entries written                    |
| `pos_ptrs`     | `[u64;32]` | 256 B  | pointer per positional argument                  |
| `pos_count`    | `u64`      |   8 B  | # of positional arguments written                |
| `error_code`   | `u64`      |   8 B  | 0 on success, else one of `ERR_*` constants      |
| `emit_schema`  | `u64`      |   8 B  | 1 iff `--pdx-schema` seen; else 0                |

Pointers into argv are **live pointers into caller-owned memory**. For
the `--foo=bar` form the parser mutates argv in place to null-terminate
the name half — this is the tokenizer.pdx precedent for in-place
null-termination and is safe because the caller owns argv and libpdx-argv
runs synchronously inside the caller's process.

`emit_schema` is set by the parser when the well-known flag `--pdx-schema`
appears in argv. It does not participate in `flag_count`: consumers ask
`if emit_schema { … }` rather than walking the flag array. This shape
lets M3's semantic-pipe integration branch cleanly on the flag without
the consumer having to string-compare each of its own `flag_names`.

## 3. Storage model

In M1 both modules keep their state in `.bss` — the singleton pattern from
`src/user/tokenizer.pdx` and `src/user/dispatch.pdx` in paideia-os. This
is deliberate for bootstrap:

- One `parse_argv` call per process. Every R49/R50 tool parses argv once
  at `_start`, then dispatches. Multi-parse (subshell, `mux` split) is a
  post-M4 concern.
- Zero heap dependency. libpdx-argv predates any allocator in the R49
  wave; every buffer is a static array.
- Trivial reset. `ParsedArgs::reset` clears three counters + the error +
  the schema flag; the arrays are consumed by index up to `flag_count` /
  `pos_count`, so stale trailing entries are unreachable.

M4 (`libpdx-argv.M4-001`) reruns the parse-correctness matrix against a
caller-owned `ParsedArgs*` variant so tests can build many contexts in
one process. That extension changes only the two module entry points —
consumers keep the same field names.

## 4. Parser state machine

`parse_argv(argv, argc)` walks argv left-to-right with an index counter.
For each `argv[i]` it inspects the first two bytes to classify:

```
byte0 = argv[i][0]
byte1 = argv[i][1]

byte0 != '-'                     → positional
byte0 == '-' && byte1 == '-'     → long flag        (--foo | --foo=bar)
byte0 == '-' && byte1 != '-'     → short flag       (M1-002)
byte0 == '-' && byte1 == 0       → positional (bare "-")
```

**Long-flag body** (M1-001). After confirming both bytes are '-', the
parser inspects `argv[i][2]`:

- `[2] == 0` — bare "--" — `ERR_LONG_MISSING_NAME`.
- `[2] == '='` — `--=…` — `ERR_LONG_MISSING_NAME`.
- otherwise walk a cursor from `argv[i]+2` looking for `'='` or NUL:
  - hit `'='` — write NUL at the `'='` byte; `name = argv[i]+2`,
    `value = (byte after '=')`. Store `(name, value)` at `flag_names[k] /
    flag_values[k]`; `k = flag_count++`.
  - hit NUL — `name = argv[i]+2`. Look at `argv[i+1]`:
    - if `i+1 < argc` **and** `argv[i+1][0] != '-'` **and**
      `argv[i+1][0] != 0` — consume it as `value`; advance `i` by an
      extra step.
    - otherwise `value = 0` (boolean flag).
  - either way check the well-known-flag table: if `name` equals
    `"pdx-schema"` byte-for-byte, set `emit_schema = 1` **in addition to**
    the normal flag storage.

**Positional body**. Store the arg ptr into `pos_ptrs[m]`; `m =
pos_count++`. Overflow past `MAX_POS` sets `ERR_POS_OVERFLOW`.

**Overflow discipline**. Every `flag_count++` and `pos_count++` compares
against `MAX_FLAGS` / `MAX_POS` **before** the write. Overflow sets
`error_code` and stops the walk. This never violates the paideia-as
`cmp reg, imm` constraint — the constants are ≤ 0x7FFFFFFF.

**`argv[0]` convention (`libpdx-argv.ENH-031`, post-1.1.0).**
`Parser::parse_argv` treats every `argv[i]` — including `argv[0]` — as
a real argv slot to classify. Every satellite `_start` passes
`argv[0] = program_name` per the frozen `execve` ABI
(`design/user/execve-abi.md`); a caller that hands the un-adjusted
`(argv, argc)` it received at `_start` straight to `parse_argv` gets
the program name silently captured into `pos_ptrs[0]` — the exact bug
`paideia-satellites/ls`'s `src/argv_surface.pdx:266-268` shipped with
before ENH-031. Rather than re-litigate the design as "parser must
skip the program name" (which breaks every non-`_start` caller that
already synthesised argv without a program name — the smoke driver
and every schema-record test module) the M1 semantics are kept
byte-identical and a companion entry point,
`Parser::parse_argv_skipping_zero`, is added. It advances `argv` by
one pointer slot and decrements `argc` by 1, then forwards to
`parse_argv`. `argc == 0` short-circuits to `parse_argv(argv, 0)`,
which returns `ERR_OK` immediately without dereferencing `argv`, so
the helper is safe on an empty or nil argv. Every `_start` consumer
should call the wrapper; the bare `parse_argv` is retained as the
lower-level primitive that classifies exactly what it is handed. See
`src/parser.pdx` `parse_argv_skipping_zero` for the two-instruction
core (`add rdi, 8; sub rsi, 1`) and its 1-push alignment prologue.

## 5. Short-flag rejection contract (M1-002 baseline; relaxed by ENH-013 §16)

When byte1 is neither `'-'` nor NUL, the arg is a short flag. D3 in
`design/tooling/plan.md` mandates one-flag-per-hyphen; the M1-002
baseline rejected every cluster (`-la`) as a category error. See §16
for the ENH-013 relaxation that admits BOOL/COUNTED clusters while
preserving the D3 guarantee for value-consuming registrations.

**Accepted (single-letter):** `-f` — a single letter followed by NUL.
Stored as `flag_names[k] = "f\0"` (interior pointer just past the `-`),
`flag_values[k] = 0`. If the next argv element does not start with `-`
or NUL, it is consumed as the value (mirrors the long-flag lookahead
rule above). Short flags do not participate in the `--pdx-schema`
well-known compare — that flag is long-only.

**Rejected (post-ENH-013):** A cluster `-abc...` where any letter's
`FlagSpec::lookup` returns a value-consuming kind (STR/INT/TIMESPAN/
SIZE/ENUM). Sets `ERR_CLUSTER_WITH_ARITY` (16); no letter is
dispatched (see §16). The erroring `argv[i]` is discoverable via the
`ParsedArgs::error_arg_index` slot the parser writes alongside every
error-code write (see `parse_argv_fail` in `src/parser.pdx`). The
legacy `ERR_CLUSTERED_SHORT` (4) is now unreachable from the parser
but retained in `ParsedArgs` for wire-form back-compat.

D3 justification survives the relaxation: a value-consuming short
flag inside a cluster (`-nX` where `-n` is INT) is still refused, so
the shell renders a one-line diagnostic per that code. The
mainstream `-vv`/`-abc` cluster idiom for BOOL/COUNTED short flags
now composes.

## 6. Compliance with paideia-as encoding constraints

Both modules follow the constraints called out in
`design/kernel/paideia-as-conformance.md` (paideia-os repo) as they apply
to the userspace toolchain at v0.33+:

- Module names are PascalCase basename (`ParsedArgs`, `Parser`) — no
  directory prefix.
- No `test` mnemonic; every zero-check uses `cmp reg, 0`.
- Every `cmp reg, imm` uses an immediate ≤ 0x7FFFFFFF (or sign-extends
  from a negative i32); no large-immediate compares.
- Register `r11` is scratch and is never assumed live across a call.
- Byte loads use `xor rax, rax; mov_b rax, [ptr]` per the paideia-as
  #1248 mitigation pattern (see the tokenizer.pdx cite in the module
  justifications).

## 7. What M1 explicitly does not do

Called out here so a reader of M1 code does not mistake absence for bug:

- No `--pdx-schema` **emission**. M1 only sets the `emit_schema` slot; a
  future M3-001 change adds `ParsedArgs::emit_argv_schema(sink)` that
  writes the parsed record to a semantic-pipe endpoint. M1 leaves the
  emission side to the consumer's own stderr, which is enough for the
  first working example the task references.
- No typed flag arguments (`--older-than 7d`). Landed in M2-001.
- No 9-flag standard vocabulary detection. Landed in M2-002. M1 treats
  every flag by grammar shape alone; the well-known names (`--help`
  etc.) are ordinary long flags to M1.
- No `doc`-back-end help rendering. Landed in M3-002.

## 8. Cross-repo dependencies

Per r49-r50-plan.md §5.12: **libpdx-argv.M1 has no library dependencies**.
The one direct paideia-os dependency is the `.pdx` module toolchain and
the R20b InitCap sidecar layout at
`src/kernel/core/loader/init_caps.pdx` — libpdx-argv reads argv memory
seeded by that layout, but never touches the sidecar itself.

paideia-as ≥ v0.33 is required by the module encoder (needed for the
`mov_b` narrow-load mnemonic and for the `@align` attribute on `.bss`
slots). Older paideia-as revisions predate the #1248 mitigation and
should not be used to build libpdx-argv.

---

## 9. M2 additions (typed flags, standard vocabulary, positional list)

M2 lands three cross-cutting extensions on top of the M1 record and
state machine. Each is scoped to one file addition or one file edit
and can be reasoned about independently. Consumers written against
M1 (there are none in-tree today — cat and rm deliberately delayed
until M2, per their `.plans/m1-002-notes.md`) migrate by adding
FlagSpec registrations at their tool's `_start`; the ParsedArgs
record shape is a superset of the M1 shape, so no reads change.

### 9.1 FlagSpec module (M2-001)

New file: `src/flag_spec.pdx`. A declarative registration table binding
a long-flag or short-flag name (NUL-terminated string) to a value kind
and a caller-chosen numeric ID. The parser consults it during argv
walking to decide arity; consumers read the same table indirectly
through `ParsedArgs::flag_ids[k]` and `flag_kinds[k]` after the parse.

**Value kinds** (`FKIND_*` constants):

| Constant | Value | Meaning |
|----------|-------|---------|
| `FKIND_BOOL`     | 0    | Arity 0 — never consumes a value (`-n`, `--help`) |
| `FKIND_STR`      | 1    | Arity 1 — opaque string (`--output foo.log`) |
| `FKIND_INT`      | 2    | Arity 1 — decoded via `Typed::parse_int_u64` |
| `FKIND_TIMESPAN` | 3    | Arity 1 — decoded via `Typed::parse_timespan` |
| `FKIND_SIZE`     | 4    | Arity 1 — decoded via `Typed::parse_size` |
| `FKIND_ENUM`     | 5    | Arity 1 — one of a caller-defined set (`--color=auto`) |
| `FKIND_UNKNOWN`  | 0xFF | Returned by `lookup` on miss; parser treats as `FKIND_BOOL` |

**API surface** (three entry points, all in `FlagSpec` module):

```
flag_spec_reset()                            // clear the table
flag_spec_register(name_ptr, kind, id)       // append (name, kind, id)
lookup(name_ptr) -> (kind, id)               // rax = kind, rdx = id
```

`flag_spec_register` silently drops past `SPEC_MAX = 32`; callers that
need overflow detection compare `spec_count` against `SPEC_MAX` before
the call. `lookup` is a linear scan (O(SPEC_MAX)) with an inline strcmp;
one call per parsed flag.

**ENH-030 (v1.1.0) rename.** The three entry points above used to be
`FlagSpec::reset` and `FlagSpec::register` (with `lookup` unchanged).
Their unmangled bare symbols collided with `ParsedArgs::reset` /
`SchemaEmit::reset` and `SchemaEmit::register` at link time whenever a
consumer linked more than one of those objects together (which every
real consumer does). The per-module prefix ends the collision.

**Cat-M1 blocker fix.** The M1 parser always consumed `argv[i+1]` as
a value for short flags when it did not start with `-` or NUL — under
that rule `cat -n foo.txt` bound `foo.txt` to `-n` and left
`pos_count == 0`. In M2 the parser calls `FlagSpec::lookup`; unknown
names (including short flags a tool has not registered) return
`FKIND_UNKNOWN` which the parser treats identically to `FKIND_BOOL`
(no lookahead). Tools that need typed short flags register them
explicitly with `FKIND_INT` / `FKIND_STR` / etc.

**Opt-in strict mode (`libpdx-argv.ENH-004`, post-1.0).** Permissive
handling of `FKIND_UNKNOWN` is correct by default — it is the cat-M1
fix above — but it means no path exists for a tool to report a
mistyped flag, which is worse in a capability OS than in POSIX because
the flag a user reaches for is frequently a restricting one
(`--dry-run`, `--no-cap:`). `FlagSpec::strict_mode` (a `.bss` u64,
zeroed by `FlagSpec::reset()`) defaults to 0; `FlagSpec::set_strict(1)`
opts in. With strict mode on, both `Parser::parse_argv` (long- and
short-flag paths) and `SchemaInvoke::parse_from_schema_record` fail
with `ParsedArgs::ERR_UNKNOWN_FLAG` (12) the moment `FlagSpec::lookup`
returns `FKIND_UNKNOWN`, before any store — `error_arg_index` carries
the offending argv index (or flag-loop index, on the schema-record
path). The long-flag check runs before the inline-value (`=`/`:`)
short-circuit, so `--nosuchflag=foo` is rejected identically to
`--nosuchflag`. See `tests/parse_grammar.pdx` cases 13-15.

**Per-registration arity policy (`libpdx-argv.ENH-010`, post-1.0).**
M1's state machine required `argv[i+1][0] != '-'` before a lookahead
consumption; M2 dropped that guard entirely when arity moved to
`FlagSpec`, so *every* typed flag with no inline value swallows
`argv[i+1]` unconditionally. That is correct for a tool-specific flag
meant to take a lookahead (`--output foo.log`), but wrong for `--color`
and `--no-cap`: I3 spells both with a mandatory separator
(`--color=<mode>`, `--no-cap:<name>`) and neither ever had a lookahead
form, so `ls --color file.txt` was silently swallowing `file.txt` as
the colour mode (`pos_count` staying 0) and `rm --no-cap --dry-run
/tmp/x` was swallowing `--dry-run` as the cap name.

Rather than a global rule change (which would break `--output
foo.log`-style tool-specific flags), ENH-010 adds a **per-registration**
arity policy:

```
FlagSpec::register(name_ptr, kind, id)     // unchanged: lookahead OR inline
FlagSpec::register_sep(name_ptr, kind, id) // NEW: inline only, ever
```

Internally, a new parallel array `spec_sep_required : [u64; 32]`
records the policy per slot (`register` writes 0; `register_sep`
writes 1). `lookup`'s own return convention stays fixed at `(kind in
rax, id in rdx)` — SysV's full multi-return pair — so the policy for
a match is published as a side effect into a companion `.bss` slot,
`last_lookup_sep_required`, the same "read a related slot right after
the call" pattern `ParsedArgs::error_code` already uses after
`Parser::parse_argv`. `Parser::parse_argv` (both long- and short-flag
paths) checks that slot immediately after every `call lookup`: if
nonzero and the flag has no inline value, it fails `ERR_MISSING_VALUE`
instead of reaching the lookahead-consumption code at all. The
short-flag path checks it too for symmetry, even though no I3 flag is
both separator-required and short-only — a short-form registration
under this policy is simply always unsatisfiable, since the
short-flag grammar has no `=`/`:` inline form to begin with.

`StdVocab::register_all` registers `--color` and `--no-cap` via
`register_sep`; the other seven standard flags are unaffected. See
`tests/parse_grammar.pdx` cases 17-20 for the fingerprint (lookahead
rejected, inline `=`/`:` unaffected) and case1 in
`tests/parse_typed_args.pdx` for the regression proof that a plain
`register()`-ed typed flag still accepts lookahead.

### 9.2 Standard vocabulary (M2-002)

New file: `src/std_vocab.pdx`. The I3 9-flag vocabulary from
`design/tooling/plan.md`:

| ID | Name        | Kind        |
|----|-------------|-------------|
| 1  | `help`      | BOOL        |
| 2  | `version`   | BOOL        |
| 3  | `dry-run`   | BOOL        |
| 4  | `json`      | BOOL        |
| 5  | `schema`    | BOOL        |
| 6  | `verbose`   | BOOL        |
| 7  | `quiet`     | BOOL        |
| 8  | `color`     | ENUM (`auto`|`always`|`never`) |
| 9  | `no-cap`    | STR (a KIND name) |

`StdVocab::register_all()` registers all nine with a single call. IDs
1..9 are reserved for the standard vocabulary; tool-specific IDs must
start at 100 (an arbitrary convention that leaves room for M3+
additions without renumbering).

**Short-form aliases are NOT registered by `StdVocab::register_all`.**
`-h` for help and `-v` for verbose collide with common per-tool short
flags (cat's `-n`, grep's `-v` for invert-match, ls's `-h` for
human-readable). Consumers register whichever short aliases they want
via explicit `FlagSpec::register` calls.

**`--color=<value>`** is a `FKIND_ENUM` flag. The parser stores the
raw value pointer in `flag_values[k]`; the consumer validates the
value against its enumerated set (e.g. by inline strcmp against
`"auto"`, `"always"`, `"never"`).

**`--no-cap:<name>`** uses `:` as the value separator per I3. The
parser accepts both `=` and `:` as separators for every long flag
(universal, not conditional on the flag name), so `--no-cap:KIND_TTY`
parses as name `"no-cap"`, value `"KIND_TTY"`.

### 9.3 Typed value parsers (M2-001)

New file: `src/typed.pdx`. Three leaf parsers, each returning a
two-value `(ok, val)` pair via the SysV `rax:rdx` return-slot pair:

```
Typed::parse_int_u64(str_ptr)   -> (rax=ok, rdx=val)
Typed::parse_size(str_ptr)      -> (rax=ok, rdx=bytes)
Typed::parse_timespan(str_ptr)  -> (rax=ok, rdx=seconds)
```

**`parse_int_u64` grammar.** `[0-9]+` terminated by NUL. Empty string
or any non-digit byte before NUL sets `ok = 0`. Multiplication by 10
uses `shl+add` (`acc*8 + acc + acc = acc*10`) — no `mul`/`imul` needed
(both are outside the R49 subset).

**`parse_size` grammar.** `[0-9]+` mantissa optionally followed by one
of `{k,K,m,M,g,G}` then NUL. Suffix semantics (binary units only at
M2 — M3 adds multi-char `KiB`/`MB`/`GB` spellings):

| Suffix | Multiplier | Shift |
|--------|------------|-------|
| (none) | 1 | 0 |
| `k`, `K` | 1024 (KiB) | `shl 10` |
| `m`, `M` | 1024² (MiB) | `shl 20` |
| `g`, `G` | 1024³ (GiB) | `shl 30` |

**`parse_timespan` grammar.** `[0-9]+` mantissa optionally followed by
one of `{s,m,h,d}` then NUL. Suffix multipliers (`w` for weeks, and
compound forms like `1h30m`, are M3):

| Suffix | Meaning | Multiplier |
|--------|---------|------------|
| (none) or `s` | seconds | 1 |
| `m` | minutes | 60 |
| `h` | hours   | 3600 |
| `d` | days    | 86400 |

The multipliers are implemented as fixed `shl+add` sequences (see the
per-arm justifications in `typed.pdx`). This keeps the encoded
instruction set inside the R49 subset — no `mul`, no `imul`, no `neg`.

**Overflow detection (`libpdx-argv.ENH-009`, post-1.0).** All three
decoders now detect rather than silently wrap on overflow, returning
`ok = 0` — the pre-existing failure contract, so no consumer changes.
Two distinct checks are involved:

- **Per-digit accumulation** (`acc = acc*10 + digit`, shared by all
  three decoders). Let `Q = floor(u64::MAX / 10) = 1844674407370955161`
  and `R = u64::MAX mod 10 = 5`. Before each step: `acc > Q` fails
  (`acc*10` alone overflows); `acc == Q && digit > R` fails
  (`acc*10 + digit` overflows); otherwise the step is safe. `Q`/`R`
  are the standard bignum "checked multiply-then-add by a small
  constant" boundary values, verified independently in Python
  (`(2**64-1)//10, (2**64-1)%10`) rather than hand-derived.
- **`parse_size`'s suffix shift** (`shl rcx, N` for `N ∈ {10,20,30}`).
  A left shift loses data iff any of the top `N` bits of the pre-shift
  mantissa are set — checked as `(mantissa >> (64-N)) != 0` via `shr`
  into a scratch register compared against 0, not by inspecting the
  shift instruction's own flags (no code in this file relies on a
  flag surviving past the next instruction).
- **`parse_timespan`'s suffix multiplier** (`mantissa * CONST` for
  `CONST ∈ {60, 3600, 86400}`; `*1` for bare seconds can never
  overflow, since the mantissa itself already passed the
  accumulation-loop gate). Unlike the per-digit case there is no
  addend after the product, so the check has no remainder
  special-case: overflow is exactly `mantissa > floor(u64::MAX /
  CONST)`. The three thresholds — `307445734561825860` (÷60),
  `5124095576030431` (÷3600), `213503982334601` (÷86400) — are
  likewise Python-verified.

All of these thresholds exceed the paideia-as `cmp reg, imm ≤
0x7FFFFFFF` cap, so every compare stages the constant through a
register first (`mov r11, <imm64>; cmp reg, r11`) rather than
comparing against the immediate directly — the same staging idiom
`libpdx-cap`'s M4-002 test matrix uses for its `0xFFFFFFxx` sentinels.
See `tests/parse_typed_values.pdx` cases 18-24, which pair each
boundary's exact-threshold success with its one-past-threshold
failure so the gate's own off-by-one risk is covered directly.

### 9.4 ParsedArgs record extensions

Four new slots + one new error code:

| slot             | type       | added at | meaning |
|------------------|------------|----------|---------|
| `flag_ids`       | `[u64;32]` | M2-002 | ID from FlagSpec::lookup (0 if unregistered) |
| `flag_kinds`     | `[u64;32]` | M2-001 | Kind from FlagSpec::lookup (FKIND_UNKNOWN if not) |
| `ddash_seen`     | `u64`      | M2-003 | 1 iff `--` sentinel was seen |
| `ddash_arg_index`| `u64`      | M2-003 | argv index of `--` (valid iff ddash_seen == 1) |
| `ERR_MISSING_VALUE = 6` | — | M2-001 | typed flag with no value available |

New helper: `ParsedArgs::find_flag_by_id(id) -> k`. Iterates
`flag_count` entries and returns the storage index whose `flag_ids[k]`
matches the caller-supplied id, or `MAX_FLAGS` (=32) on miss. Consumer
usage:

```
let k = ParsedArgs::find_flag_by_id(StdVocab::STD_ID_HELP)
if k != 32 { /* --help was seen — dispatch help + exit */ }
```

**Duplicate-flag policy (`libpdx-argv.ENH-008`, post-1.0).** Neither
`Parser::parse_argv` nor `SchemaInvoke::parse_from_schema_record`
de-duplicates — every occurrence of a repeated flag gets its own slot
in `flag_names`/`flag_values`/`flag_ids`/`flag_kinds`. Prior to
ENH-008 the only accessor, `find_flag_by_id`, was first-wins by
construction (it scans upward and returns on the first match) with no
policy stated anywhere. ENH-008 keeps `find_flag_by_id`'s behaviour
and documents it explicitly as first-wins, and adds two companions:

- `ParsedArgs::find_last_flag_by_id(id) -> k` — scans downward from
  `flag_count-1`, so a later occurrence shadows an earlier one (the
  mainstream-CLI / shell-alias-composability convention: `--color=auto
  --color=never` resolves to `never`).
- `ParsedArgs::count_flag_by_id(id) -> u64` — full scan tallying every
  occurrence, for the repeat-count idiom (`-v -v -v` for a verbosity
  level, where the count itself is the signal, not any one slot).

No existing consumer's behaviour changes — `find_flag_by_id` is
untouched — this is purely additive. See `tests/parse_grammar.pdx`
case 16.

### 9.5 `--` sentinel (M2-003)

The parser tracks a single-bit sentinel: once `--` is seen at
`argv[i]`, `ddash_seen` is set to 1, `ddash_arg_index` to `i`, and the
loop head unconditionally routes every subsequent `argv[j]` to the
positional branch — regardless of whether it starts with `-`, is bare
`-`, or looks like `--foo`. The sentinel itself is not stored in
`pos_ptrs` (its role is metadata; consumers that want to reconstruct
the original argv position of the sentinel read `ddash_arg_index`).

### 9.6 Parser register-plan change (M2-001)

The M1 parser was leaf; every register was caller-save. M2 makes it
non-leaf (one `call FlagSpec::lookup` per parsed flag). The register
plan shifts loop state into callee-save regs and adds a prologue:

```
push rbx   ; rsp%16: 8 → 0
push rbp   ; rsp%16: 0 → 8
push r12   ; rsp%16: 8 → 0
push r13   ; rsp%16: 0 → 8
push r14   ; rsp%16: 8 → 0
push r15   ; rsp%16: 0 → 8
sub  rsp, 8 ; rsp%16: 8 → 0
; body ...
add  rsp, 8
pop r15
pop r14
pop r13
pop r12
pop rbp
pop rbx
ret
```

Callee-save assignments during the body:

- `rbx` = argv base (was M1's `r9`)
- `rbp` = name pointer preserved across `FlagSpec::lookup`
- `r12` = argc (was M1's `r10`)
- `r13` = loop index `i` (was M1's `r8`)
- `r14` = value pointer preserved across the call (0 = boolean)
- `r15` = id returned by `lookup`, preserved for the store sequence

Caller-save `rax` holds the kind between the lookup return and the
store; every intermediate op deliberately avoids touching `rax` so
the flag_kinds write can consume it directly (see the two `cmp rax,
...` branches after the `mov r15, rdx` line).

### 9.7 What M2 explicitly does not do

- Multi-char suffixes (`KiB`, `MiB`, `min`, `hour`) — M3.
- Compound timespans (`1h30m`, `7d12h`) — M3.
- Negative integers / signed ints — M3.
- Comparison operators (`--size > 1MB`) — M3 or later; the `>` and
  `1MB` are separate argv entries at M2, and the tool's own DSL
  layer decodes them.
- Alternate invocation path: typed schema record → ParsedArgs — M3-001.
- `--help` back-end integration with `doc <tool>` — M3-002.
- `--schema` printing the tool's declared output schemas — M3-003.
- Semantic-pipe emission — M3-001.
- Signed release + `.pdxdoc` — M5-001.

---

## 10. M3 additions (schema invocation, doc back-end, --schema emit)

M3 lands three independent extensions on the M2 foundation. None of
them changes the ParsedArgs read shape; each adds either a new module,
a new set of error codes, or a new entry-point that fills the same
ParsedArgs a M2 consumer already reads. A M2 consumer can pick up any
subset of M3 without touching its existing dispatch code.

### 10.1 Alternate invocation: typed schema record → ParsedArgs (M3-001)

New file: `src/schema_invoke.pdx`. Module `SchemaInvoke` with one
entry point:

```
SchemaInvoke::parse_from_schema_record(record_ptr, record_len) -> u64
```

**Wire form (v1).** The entire record body sits in caller-owned memory
that libpdx-argv borrows exactly the way it borrows argv. Every
pointer written into ParsedArgs is computed as `record_ptr + offset`
and stays live as long as the caller keeps the record buffer alive.

| offset | size | field |
|--------|------|-------|
| 0 | 8 | magic = `"PDXARGV\0"` ASCII (0x50 0x44 0x58 0x41 0x52 0x47 0x56 0x00) |
| 8 | 8 | version (u64 LE; must equal `SCHEMA_VERSION_V1 = 1`) |
| 16 | 8 | flag_count (u64; 0..MAX_FLAGS=32) |
| 24 | 8 | pos_count (u64; 0..MAX_POS=32) |
| 32 | 16 · flag_count | flag entries — each is `{u64 name_off, u64 value_off}` |
| next | 8 · pos_count | positional entries — each is `u64 pos_off` |
| rest | — | string table (NUL-terminated strings; opaque here) |

**Semantics.**

- `name_ptr = record_ptr + name_off` for every flag; the sender lays
  out the string table such that each `name_off` points at a NUL-
  terminated bytestring.
- `value_off == 0` marks a boolean flag (no value stored); otherwise
  `value_ptr = record_ptr + value_off` (same NUL-terminated shape).
- For each flag, `SchemaInvoke` calls `FlagSpec::lookup(name_ptr)` and
  writes `(kind, id)` into `ParsedArgs::flag_kinds[k]` /
  `ParsedArgs::flag_ids[k]` — identical semantics to `Parser::parse_argv`
  so a consumer's `find_flag_by_id` dispatch is invocation-path
  agnostic.
- On error `error_code` is set to one of the three new codes below,
  and `error_arg_index` carries the flag/pos loop index at failure
  (0 for header failures).

**New error codes** (in `ParsedArgs`):

| Constant | Value | Meaning |
|----------|-------|---------|
| `ERR_SCHEMA_BAD_MAGIC`           | 7 | Bytes 0..8 did not match `"PDXARGV\0"`. |
| `ERR_SCHEMA_UNSUPPORTED_VERSION` | 8 | Version qword != 1. |
| `ERR_SCHEMA_BAD_LAYOUT`          | 9 | Record < 32 B, or count > MAX, or body-fits check failed. |
| `ERR_SCHEMA_BAD_OFFSET`          | 10 | A `name_off`/`value_off`/`pos_off` was 0 (name/pos) or `>= record_len` (`libpdx-argv.ENH-001`). |
| `ERR_SCHEMA_UNTERMINATED`        | 11 | A validated offset's string ran to `record_ptr + record_len` with no NUL byte (`libpdx-argv.ENH-001`). |

**Wire-integer compares are unsigned (`libpdx-argv.ENH-002`).**
`record_len`, `flag_count` and `pos_count` are u64 fields read straight
off an untrusted frame; the header-size, count-cap and body-fits gates
compare them with `jb`/`ja` (unsigned), not `jl`/`jg`. A signed compare
let a wire value with bit 63 set (e.g. `flag_count = 0xFFFFFFFFFFFFFFFF`)
pass the `> 32` cap as a "negative" number, wrap `flag_count * 16`, and
land the positional-array base inside the 32-byte header — handing the
consumer offsets read out of the magic/version qwords. It symmetrically
let a huge `record_len` (bit 63 set) fail the `< 32` header-size gate
even though the caller-supplied length was actually far larger than
required. See `tests/parse_schema_record.pdx` cases 7–8.

**Preconditions.** `parsed_args_reset()` and `FlagSpec` registration
must have happened before the call. The consumer's `_start` sequence
becomes:

```
flag_spec_reset()                    // ENH-030 v1.1.0
register_all()                       // StdVocab
flag_spec_register(tool_specific ...)
parsed_args_reset()

if invoked_via_argv:
    parse_argv(argv, argc)
else:                                # invoked via semantic-pipe
    parse_from_schema_record(rec_ptr, rec_len)

// downstream dispatch identical on both paths
```

**Offset + terminator validation (`libpdx-argv.ENH-001`, post-1.0).**
At M3-001 every `name_off` / `value_off` / `pos_off` was trusted to
point at a NUL-terminated bytestring inside the record with no range
check at all — an unbounded read on this library's only untrusted-input
surface (a peer process across a `KIND_IPC_ENDPOINT`). This was closed
by `libpdx-argv.ENH-001`: every nonzero name/value/pos offset must
satisfy `off < record_len` (unsigned — see the ENH-002 rationale above;
`off == 0` is additionally rejected for name/pos offsets, since only
`value_off` has a zero-sentinel meaning), and the resulting pointer is
scanned for a NUL byte before `record_ptr + record_len` — an
unterminated string fails with `ERR_SCHEMA_UNTERMINATED` rather than
letting `FlagSpec::lookup`'s byte-by-byte strcmp walk off the end of
the frame. `FlagSpec::lookup` is never called on a pointer that failed
either gate. See `tests/parse_schema_record.pdx` cases 9–10.

**What M3-001 does NOT validate (unchanged from launch).**

- `ddash_seen` and `emit_schema`. The schema-record shape has no
  literal `--` sentinel and no `--pdx-schema` well-known-flag; a
  sender that wants either concept expresses it via a registered
  flag id and its consumer's dispatch table. `SchemaInvoke` leaves
  both `ParsedArgs` slots at whatever value `ParsedArgs::reset` left
  them (i.e. 0).

**Non-leaf / SysV alignment.** `parse_from_schema_record` is non-leaf
(one `call FlagSpec::lookup` per stored flag). The prologue mirrors
`Parser::parse_argv` exactly: push rbx/rbp/r12/r13/r14/r15 + `sub
rsp, 8` = 7 stack slots after the return address, so `rsp % 16 == 0`
at every nested call site.

### 10.2 `--help` back-end integration with `doc <tool>` (M3-002)

New file: `src/help_backend.pdx`. Module `HelpBackend` with one
public `.rodata` symbol and one leaf helper:

```
HelpBackend::DOC_TOOL_NAME     : [u8; 4]     // "doc\0"
HelpBackend::fill_doc_argv(out_argv_slot_ptr, tool_name_ptr) -> ()
```

**Why an argv-fill primitive, not a fn-pointer dispatcher.** libpdx-
argv cannot statically link against `doc` — the reverse dependency
already holds (`doc` uses libpdx-argv). A fn-pointer table would work
but at bootstrap-scope every P0 tool is one statically-linked binary
that knows at link time which `doc_dispatch` symbol to call. The
argv-fill helper lets the caller synthesize the two pointers once and
hand them to whichever entry it linked; no indirect call, no
per-invocation registration.

**Consumer wiring pattern.**

```
let k = ParsedArgs::find_flag_by_id(StdVocab::STD_ID_HELP)
if k != 32 {
  let mut argv_slots : [u64; 2] = uninit @align(8)
  HelpBackend::fill_doc_argv(&argv_slots[0], my_tool_name_ptr)
  exit(DocDispatch::doc_dispatch(&argv_slots[0], 2))
}
```

Once fork/exec substrate lands (R51+), the same fill_doc_argv output
can seed the child's argv instead of an in-process call — the two
pointers are the invariant, the transport is not.

**Why a shared `DOC_TOOL_NAME` symbol.** Every consumer's synthesized
argv[0] agrees byte-for-byte, so a shell-side audit-record consumer
can recognise the "doc" tool without normalising per-caller
whitespace or case. The symbol is 4 bytes; the cost of the shared
copy is negligible.

### 10.3 `--schema` prints declared output schemas (M3-003)

New file: `src/schema_emit.pdx`. Module `SchemaEmit` with a four-call
API that mirrors FlagSpec's storage-then-lookup shape:

```
SchemaEmit::reset()                       // clear the table
SchemaEmit::register(schema_name_ptr)     // append; drops past SCHEMA_MAX=8
SchemaEmit::get_count() -> u64            // for iteration
SchemaEmit::get_name(idx) -> u64          // per-slot ptr (0 if idx OOR)
```

**Storage-only, not I/O.** libpdx-argv holds no capability (see
`caps.decl`: "libpdx-argv requires no caps of its own"). SchemaEmit
owns the *table* of declared schema names; the actual write to
stdout is the consumer's responsibility (which holds the KIND_TTY /
KIND_IPC_ENDPOINT cap for stdout). This split keeps the library
untouched by the R42-blocked I/O substrate and cleanly testable at M4.

**Consumer pattern.**

```
at _start:
  SchemaEmit::reset()
  SchemaEmit::register(&SCHEMA_NAME_A)   // e.g. "MyToolRecord@0.1\0"
  SchemaEmit::register(&SCHEMA_NAME_B)

at --schema dispatch:
  let k = ParsedArgs::find_flag_by_id(StdVocab::STD_ID_SCHEMA)
  if k != 32 {
    let n = SchemaEmit::get_count()
    let mut i = 0
    while i < n {
      write_line(stdout_fd, SchemaEmit::get_name(i))
      i = i + 1
    }
    exit(0)
  }
```

**Cap on 8 schemas.** Every P0 tool's observed maximum is 3 (`pkg`
declares PackageManifest[], InstallProgressRecord[], and
KeyFingerprintRecord[]). SCHEMA_MAX = 8 leaves 5× headroom without
inflating the .bss footprint (64 B for the array + 8 B for the count).
Over-registrations silently drop; consumers wanting the diagnostic
compare `schema_count` against their intended count after the batch.

### 10.4 What M3 explicitly does not do

- Runtime parse of `caps.decl` `declares_output_schemas:` — the
  consumer bakes its schema list into `.rodata` and registers them
  by pointer. Runtime `caps.decl` parsing is a post-M5 concern gated
  on the `pdx-help` library.
- Fork/exec of `doc` — the `HelpBackend::fill_doc_argv` output is the
  argv the caller passes to whichever `doc_dispatch` entry it linked;
  the actual process spawn is R51+ substrate.
- Wire-form v2 for the semantic-pipe record — the M3 shape is v1;
  a compound `flag_group` or per-flag `kind` override would land as
  v2 alongside a coordinated libpdx-semantic-pipe schema fingerprint
  bump.
- Per-string-terminator validation on the schema record — deferred at
  M3/M4, landed post-1.0 as `libpdx-argv.ENH-001` (see §10.1).

---

## 11. M4 additions (parse-correctness matrix + smoke driver)

M4 lands a self-contained test tree under `tests/` that exercises
every public entry the library shipped through M3. Nothing about the
library's own API changes at M4 — the addition is fixtures + a
driver that packages the tally into a smoke exit code.

### 11.1 Test-harness shape

`tests/harness.pdx` — module `TestHarness`. Public surface:

| symbol | kind | purpose |
|--------|------|---------|
| `pass_count`      | `.bss u64` | incremented by every green case |
| `fail_count`      | `.bss u64` | incremented by every red case |
| `last_fail_tag`   | `.bss u64` | `(module_id<<32) \| case_number` of the last failure |
| `reset_tally()`   | leaf       | zero all three counters |
| `record_pass()`   | leaf       | `pass_count++` |
| `record_fail(tag)`| leaf       | `fail_count++`, `last_fail_tag = tag` |
| `full_reset()`    | non-leaf   | zero `ParsedArgs` + `FlagSpec` + `SchemaEmit` singletons |

The singleton pattern mirrors the library — the caller-owned
`ParsedArgs*` variant referenced in §3 is a post-M5 concern, and
until it lands the harness must reset the same singletons every
test writes into.

### 11.2 Module-id table

Every fixture module owns a module-id used in the `last_fail_tag`
encoding. IDs 1–9 are reserved so future test additions do not
reshuffle case numbers.

| ID | Module (file)                            | Cases (M4-001) |
|----|------------------------------------------|:--:|
| 1  | `ParseGrammarTests` (parse_grammar.pdx)  | 20 |
| 2  | `ParseTypedValuesTests` (parse_typed_values.pdx) | 24 |
| 3  | `ParseTypedArgsTests` (parse_typed_args.pdx) | 5  |
| 4  | *reserved* (parse_positional_ext)         | —  |
| 5  | `ParseStdVocabTests` (parse_std_vocab.pdx) | 4  |
| 6  | `ParseSchemaRecordTests` (parse_schema_record.pdx) | 10 |
| 7  | `HelpBackendTests` (help_backend.pdx)     | 4  |
| 8  | `SchemaEmitTests` (schema_emit.pdx)       | 5  |
| 9  | *reserved* (parse_mixed_ext)              | —  |

Fail-tag encoding: `(module_id << 32) | case_number`. All tag values
are ≥ 2³², forcing the `mov reg, imm64` encoder path — this is
deliberate so a smoke run also exercises the R48 imm64 sweep.

### 11.3 Wire-form fixture rationale

`parse_schema_record.pdx` hand-codes 65-byte / 32-byte / 16-byte
`.rodata` records against the layout in §10.1 (magic + version +
counts + flag/positional offsets + string table). This is deliberate:

- The test IS the layout pin — any offset drift in `SchemaInvoke`
  breaks the smoke, which is the correct signal for a coordinated
  `PdxArgvRecord@0.1` schema-fingerprint negotiation with
  libpdx-semantic-pipe M2.
- Rejection cases (bad magic, bad version, short header, oversize
  count, body-fits fail) cover the five ERR_SCHEMA_* diagnostic
  paths declared in §10.1.

The happy-path fixture (case1) also drives the alt-invocation
find_flag_by_id contract: after `SchemaInvoke::parse_from_schema_
record`, a `--help` stored via the schema-record path is discoverable
by `ParsedArgs::find_flag_by_id(STD_ID_HELP)` — identical semantics
to the argv path (see §10.1 postconditions).

### 11.4 Smoke-driver exit code

`tests/smoke_driver.pdx` — `SmokeDriver::_start`:

1. `TestHarness::reset_tally()` — zero counters.
2. Call every `run_case*` in module order (no reordering — driver
   order matches tests/README.md).
3. Pack `(pass_count << 16) | fail_count` and hand to
   `SysExit::exit(code)`.

`SysExit::exit` is a link-time symbol; the smoke-binary wiring layer
supplies the actual syscall bridge (analogous to
`src/user/syscall_shim.pdx` in paideia-os). libpdx-argv itself
holds no caps and cannot syscall — the driver's job is to package
the tally; the wiring's job is to hand it out.

A shell wrapper (analogous to `tools/verify-user-tokenizer.sh` in
paideia-os) that assembles + boots + interprets the exit code lands
with `pkg.M4` — see the M4→M5 dependency chain in
`design/tooling/r49-r50-plan.md` §5.12.

### 11.5 What M4 explicitly does not do

- `--help` output byte-diff against a golden `.pdxdoc` render — needs
  `doc.M2` runnable; libpdx-argv's obligation stops at the argv-
  synthesis contract (verified in `help_backend.pdx`).
- Property-based / fuzz driver — M5+; needs pkg wiring.
- Concurrent multi-parse — M2/M3 ParsedArgs is singleton-scoped.
- MAX_POS / MAX_FLAGS overflow tests — 32-slot cap is heavily
  overprovisioned for every observed P0 tool (max 12 flags + 4 pos
  in `pkg install`); a dedicated stress test is a M4+ stretch.

## 12. `--version` auto-emitter (ENH-032, Closes #25)

`StdVocab::register_all` reserves `--version` (id 2) but the M2 shape
left every consumer to re-implement the emit path — build the
`<tool> <ver>\n<TOOL> VERSION OK\n` byte sequence in tool-local
`.rodata`, sys_write it, exit 0. Six live P0 satellites
(`mkfs.pdxfs`, `mount.pdxfs`, `umount.pdxfs`, `libpdx-audit`,
`libpdx-elevate`, `shell`) each ship 20-odd lines of near-identical
boilerplate to do this. `libpdx-argv.ENH-032` lifts the emit into a
new library module `VersionBackend` (file `src/version_backend.pdx`);
`Parser::parse_argv` dispatches to it when it observes an argv slot
equal to `--version` AND `VersionBackend::override_enabled == 0`.

### 12.1 Module surface

| symbol | kind | purpose |
|--------|------|---------|
| `override_enabled`        | `.bss u64` | 0 → auto-emit fires; non-0 → tool renders its own |
| `LIT_SPACE`               | `.rodata` [u8;2] | `" \0"` — space between tool + version |
| `LIT_NEWLINE`             | `.rodata` [u8;2] | `"\n\0"` — newline between the two lines |
| `LIT_VERSION_OK`          | `.rodata` [u8;13] | `" VERSION OK\n\0"` — legacy fingerprint tail |
| `DOC_TOOL_NAME_UPPER`     | `.rodata` [u8;4] | `"DOC\0"` — coupled uppercase of `HelpBackend::DOC_TOOL_NAME` |
| `DOC_TOOL_NAME_UPPER_LEN` | `.rodata u64` | 3 — length of the uppercase payload |
| `DOC_TOOL_NAME_LEN`       | `.rodata u64` | 3 — length of the lowercase payload |
| `pdxargv_version_reset()` | leaf | zero `override_enabled` |
| `set_override(on: u64)`   | leaf | store `on` into `override_enabled` |
| `version_strlen(s: u64) -> u64` | leaf | byte-loop strlen |
| `emit_default() -> ()`    | non-leaf | seven sys_writes realising the fingerprint |

### 12.2 Extern symbol

`PDX_TOOL_VERSION` is a NUL-terminated ASCII string in `.rodata`
defined per-tool at build time in a per-repo constants module. The
reference in `version_backend.o` is an UND relocation resolved at
final-link time. Consumers that link libpdx-argv without defining
`PDX_TOOL_VERSION` fail at ld with an undefined-symbol error naming
the missing symbol — a build-time catch, not a run-time surprise.

The tests/ tree carries an in-repo stub
(`SmokeDriver::PDX_TOOL_VERSION = "1.2.0-libpdx-smoke\0"`) so the
smoke binary can link end to end and exercise the auto-emit case
against a real fd-1 write.

### 12.3 Dispatch shape in `parse_argv`

After every long-flag or short-flag store, `parse_argv` runs:

```
cmp r15, 2                    ; STD_ID_VERSION
jne <not-version>
lea r11, [rip + override_enabled]
mov r10, [r11]
cmp r10, 0
jne <not-version>
call emit_default
mov rax, 13                   ; ERR_VERSION_EMITTED
jmp parse_argv_fail
<not-version>:
```

The dispatch is by id, not by name compare — a tool that registers
`--version` with a non-2 id (say 100) keeps StdVocab's other 8 flags
but takes the emit path itself. The nested call to `emit_default` is
aligned by parse_argv's own 6-push + sub rsp,8 prologue; no
additional frame bookkeeping is needed.

### 12.4 Contract with the legacy fingerprint

The `<TOOL> VERSION OK\n` line is deliberate: several paideia-os
smoke fixtures grep for it (`grep -q 'VERSION OK'`) as their
`--version` sentinel. Dropping the line would invalidate half a
dozen downstream smoke drivers on the same commit. Once every
downstream driver switches to a schema-parsed `.pdxrec` check for
tool version detection (post-R51), the legacy line can retire.

### 12.5 What ENH-032 explicitly does not do

- Per-tool `DOC_TOOL_NAME`. Every tool's auto-emit currently says
  `doc <ver>\nDOC VERSION OK\n` because `HelpBackend::DOC_TOOL_NAME`
  is the fixed literal `"doc\0"`. Making it per-tool is a follow-on
  ENH (promote `DOC_TOOL_NAME` and `DOC_TOOL_NAME_UPPER` to a
  paired extern/weak symbol supplied alongside `PDX_TOOL_VERSION`).
- Build-hash / signing-key fingerprint in the auto-emit output.
  Tools that need that line render their own `--version` via
  `set_override(1)`; the library's fingerprint is deliberately
  minimal so the emit is a single byte-sequence contract.
- Runtime uppercase-conversion of `DOC_TOOL_NAME`. The coupled
  `DOC_TOOL_NAME_UPPER` literal saves the tool-per-invocation
  conversion cost; if `DOC_TOOL_NAME` ever varies, add the
  conversion here rather than in every downstream tool.

## 13. INT flag range validation (ENH-018, Closes #28)

Pre-ENH-018 the INT decoder path was value-agnostic: `Typed::parse_int_u64`
accepts any decimal string that fits in `u64` (post-ENH-009 the decoder
rejects `u64::MAX + 1` cleanly instead of wrapping, but that gate is the
only value-shaped one it applies). Every INT-flag consumer that needed
"the number must be between 1 and 64" re-implemented the same clamp
after the decode, five to ten lines of near-identical boilerplate per
call site with no shared error code. ENH-018 lifts the interval check
into the library.

### 13.1 Module surface delta

`FlagSpec` grows two `[u64; 32]` .bss arrays (`spec_min`, `spec_max`)
and two exported functions:

- `register_int(name_ptr, id, min, max)` — appends `(name, FKIND_INT,
  id)` with `(min, max)` published into the new slots. Kind is
  fixed to `FKIND_INT` (2) rather than taken from the caller:
  `register_int` is the INT-specific superset of `flag_spec_register`,
  and a caller registering something non-INT should call the plain
  path (which now also clears the range slots to `(0, 0)` so a slot
  recycled after a `register_int` never inherits stale bounds).
- `get_range_by_id(id) -> (min in rax, max in rdx)` — linear scan of
  `spec_ids`, returning `(spec_min[i], spec_max[i])` for the first
  matching slot, or `(0, 0)` if no slot matches. Deliberately does
  NOT skip `id==0` slots (unlike `ParsedArgs::find_flag_by_id`'s
  ENH-024 skip): here the caller-supplied `id` would only be 0 if
  they registered a flag with `id=0`, which is a caller-side
  contract violation (0 is reserved for "unregistered" in the
  `FlagSpec` id-space) and matching such a slot is either a
  diagnostic accident the caller wants to see or a no-op tolerable
  at `get_range_by_id`'s return contract.

`Typed` grows one exported function:

- `parse_int_u64_ranged(str_ptr, min, max) -> (ok in rax, val in rdx)`
  — delegates decoding verbatim to `parse_int_u64`, then applies the
  gate. NON-leaf; the module's compliance preamble carries an
  explicit "EXCEPTION" line naming this function because every other
  `Typed::*` is leaf.

`ParsedArgs` grows one error-code constant:

- `ERR_INT_RANGE : u64 = 14` — set by `parse_int_u64_ranged` on a
  range violation.

### 13.2 Sentinel contract: (0, 0) means "range OFF"

The `(min = 0, max = 0)` pair is treated as "range OFF" and bypasses
the gate entirely, so `parse_int_u64_ranged("x", 0, 0)` behaves
identically to `parse_int_u64("x")` — the same `(ok, val)` return, the
same `ParsedArgs::error_code` non-touch. This is deliberate: the plain
`flag_spec_register(name, FKIND_INT, id)` path writes `(0, 0)` into
`spec_min` / `spec_max`, so a flag registered via the plain path is
transparent to the gate. A consumer that wants an interval legitimately
starting at 0 (e.g. `[0, 100]`) sets `max = 100` with `min = 0`, which
lifts the pair out of the sentinel because the sentinel requires BOTH
slots to be 0.

The alternative sentinel `max == 0` alone was rejected: it does not
compose — a caller who legitimately writes `register_int(..., 5, 10)`
and later reduces the upper cap to 0 by hand cannot then re-arm the
gate without also touching `spec_min`. The (0, 0) pair is the only
sentinel that survives every arithmetic manipulation.

### 13.3 Gate discipline: unsigned end to end

The gate uses `jb` (val < min) and `ja` (val > max) — unsigned compares
end to end. This is the difference between accepting and rejecting
`parse_int_u64_ranged("18446744073709551615", 1, 64)`: `u64::MAX` in
two's-complement signed reads as -1, so a signed `jg` would erroneously
report `-1 < 64` and pass the value through. The unsigned `ja` sees
`u64::MAX > 64` and rejects. Case 28 in `parse_typed_values_tests.pdx`
is the regression fixture that locks this in — pairing it with case 18
(which proves the decoder accepts `u64::MAX` at ok=1) proves the
rejection comes from the range gate, not from an intermediate overflow.

### 13.4 Error-code discipline

`parse_int_u64_ranged` writes `ParsedArgs::error_code = ERR_INT_RANGE`
ONLY on a range violation. A decode failure (the underlying
`parse_int_u64` returning `ok=0`) leaves `error_code` untouched — the
pre-ENH-018 `Typed` convention that a decode failure does not set an
error_code is preserved so a consumer that only inspects the `ok`
return behaves the same whether it called `parse_int_u64` or
`parse_int_u64_ranged`. `error_arg_index` is deliberately NOT touched
by the range gate either: the consumer knows which flag it was
decoding (typically via a `k = find_flag_by_id()` index, which is a
flag index into ParsedArgs, not an argv index) and setting an argv
index here would misalign with the `parse_argv` contract that only the
argv classifier writes that slot.

Klog tag for the range trip: `pdxargv.int-range`.

### 13.5 What ENH-018 explicitly does not do

- No `register_int_sep` variant. A tool that wants a bounded INT
  flag whose spelling ALSO mandates a separator (`--foo=42` only,
  never `--foo 42`) has to compose that via `register_sep()`
  followed by a manual post-hoc `spec_min` / `spec_max` write.
  Promoting the compose into a first-class variant is a follow-on
  ENH; no consumer needs it today.
- No range check inside the parser proper. `Parser::parse_argv`
  still classifies-and-stores; the range check runs at the
  dispatch-site `Typed::parse_int_u64_ranged` call. Reason: the
  parser has no natural place to invoke the decoder (some INT
  flags are optional, and the decoder is a mem-effect leaf whose
  own overflow gate the parser has never been in the business of
  triggering), and pushing the check into the parser would double
  the number of state-machine transitions per parsed INT flag.
- `get_range_by_id` does not distinguish "registered with no
  range" from "not registered at all" — both return `(0, 0)`, by
  design. Callers that need to tell them apart call `lookup()`
  first (a `FKIND_UNKNOWN` return means "not registered", any
  other return means "registered").

## 14. Auto `--help` table fallback (ENH-014, Closes #24)

`StdVocab::register_all` reserves `--help` (id 1). M3-002 wired
the observation through `HelpBackend::fill_doc_argv` into whichever
`doc_dispatch` symbol the consumer statically linked. That leaves
a gap: a tool built WITHOUT `doc` linked has no fall-back — it
either has to render `--help` by hand (defeating the M3-002 point)
or it emits nothing at all. ENH-014 lands the in-process fallback:
a walk over the registration table that writes one
`--<name><TAB><help>\n` line to fd 1 per registration whose help
slot is populated, followed by `ERR_HELP_EMITTED` (15) via the
shared `parse_argv_fail` epilogue.

### 14.1 Module surface delta

New in `FlagSpec`:

- `spec_help : [u64; 32]` .bss array — one help-text pointer per
   registration slot; `0` means "no help text on this row".
   Defensively zeroed by every plain registration path
   (`flag_spec_register`, `register_sep`, `register_int`) so a
   slot recycled across a `register_with_help() →
   register_sep()` sequence never inherits stale bits.
- `register_with_help(name_ptr, kind, id, help_ptr)` — the
   canonical full-shape registration path. `flag_spec_register`
   is now a thin wrapper that xors rcx to 0 and tail-calls
   `register_with_help`, preserving the M2 3-arg surface every
   existing consumer already targets.

New in `HelpBackend`:

- `LIT_DDASH` / `LIT_TAB` / `LIT_LF` — the three `.rodata`
   literals `emit_from_argspec` writes verbatim per row
   (`--`, `\t` = 0x09, `\n` = 0x0A).
- `doc_backend_unavailable : u64` .bss slot — 0 (default) means
   the M3-002 dispatch is in effect; nonzero means the tool has
   opted into the fallback.
- `pdxargv_help_reset()` — leaf; zeros the gate slot. Wired
   into `TestHarness::full_reset`.
- `set_doc_unavailable(on)` — leaf; stores rdi into the gate
   slot.
- `help_strlen(s)` — leaf; byte-loop strlen mirroring
   `VersionBackend::version_strlen` in shape (per-module copy so
   `help_backend.o` has no link dependency on
   `version_backend.o`).
- `emit_from_argspec()` — non-leaf; 3-push prologue
   (rbx / r12 / r13). Walks `spec_names` / `spec_help` /
   `spec_count`, issuing 5 `sys_write`s per non-null row (literal
   `--`, name, TAB, help, LF); rows whose help slot is 0 are
   silently suppressed. Called by `Parser::parse_argv` on the
   auto-emit path.

New in `ParsedArgs`:

- `ERR_HELP_EMITTED : u64 = 15` — parity with
   `ERR_VERSION_EMITTED` (a success signal, not an error). The
   parser writes it into `error_code` and returns it in rax via
   the shared `parse_argv_fail` epilogue.

### 14.2 Opt-in gate rationale

The gate is opt-IN so existing consumers see zero behavior change
on `--help`. Every P0 tool today statically links `doc` and
dispatches `--help` through its own code path; flipping the
default to auto-emit would silently break that dispatch (the tool
would exit before its `find_flag_by_id(STD_ID_HELP)` handler
ever ran). A tool built without `doc` — the case ENH-014 exists
for — is a positive signal the tool's author makes at bootstrap:
`HelpBackend::set_doc_unavailable(1)`. Everything downstream is
identical to the with-doc case up to that call.

This is inverted from ENH-032's `--version` gate, where the
default is auto-emit and the opt-out is `set_override(1)`. The
inversion is deliberate: `--version` had no shared M-series
dispatch (every consumer already hand-rolled the emit path), so
consolidating into a library-owned default carried no behavior
break. `--help` did have a shared dispatch (M3-002); preserving
it as the default keeps consumers stable.

### 14.3 Dispatch shape in `parse_argv`

After every long-flag OR single-letter short-flag store, the
parser checks whether the just-stored id equals
`StdVocab::STD_ID_HELP` (1) AND `doc_backend_unavailable != 0`.
On both hits it calls `emit_from_argspec`, loads rax with 15, and
jumps to `parse_argv_fail`. The 6-push + `sub rsp,8` prologue
that already aligned `rsp%16 = 0` for the nested
`FlagSpec::lookup` and `VersionBackend::emit_default` calls
covers this without any bookkeeping change.

StdVocab does not register a `-h` alias (it would collide with
`head` / `hexdump` conventions), so the short-flag path only
fires for a tool that has explicitly registered a single-letter
short flag with id `STD_ID_HELP`. Consumers wanting a `-?` or
`-h` alias get it by calling `flag_spec_register(&NAME_H,
FKIND_BOOL, 1)` after `register_all`.

### 14.4 Row-suppression semantics

`emit_from_argspec` skips any row whose `spec_help[i]` is 0. This
lets a tool populate help text for only its most user-facing
flags while leaving diagnostic-only or debug flags untabulated
without having to move them to a separate `FlagSpec` table. The
walk visits registrations in registration order so the on-screen
table matches source order in the tool's bootstrap.

### 14.5 What ENH-014 explicitly does not do

- No pagination. `emit_from_argspec` writes every non-null row
  in one pass. A tool with > 20 flags would benefit from
  paginated output; deferred until a real consumer needs it.
- No group headers or per-section formatting. The output is a
  flat two-column table; consumers wanting `Usage:` / `Options:`
  banner text render it themselves via their own sys_write
  before/after the auto-emit path fires (the parser fires the
  emit before returning, so a wrapping `--help` handler would
  have to intercept the return code and render a header on
  ERR_HELP_EMITTED before exiting).
- No wire-form auto-emit. The schema-record invocation path
  (`SchemaInvoke::parse_from_schema_record`) does not fire the
  fallback; a peer tool feeding a `--help` observation through
  the pipe does not want text on fd 1. The auto-emit is scoped
  to the argv invocation path only.
- No `-h` short alias registered by StdVocab. See §14.3.
- No cap acquisition. `emit_from_argspec` writes to fd 1 with
  whatever cap the caller already holds; libpdx-argv holds none
  of its own. Consumers that lack a KIND_TTY / KIND_IPC_ENDPOINT
  cap on fd 1 see the syscalls fail with EBADF and this function
  returns anyway — same silent-write policy `emit_default` uses.

## 15. Structured error emission (ENH-016, Closes #26)

Before this ENH, a parse failure surfaced only as the scalar
`ParsedArgs::error_code` plus `error_arg_index`; the semantic-pipe
path had nothing to hand back to an auditor or a peer tool that
wanted machine-readable diagnostics. ENH-016 lands the first
OUTPUT wire schema this library declares — `PdxArgvParseErrorRecord@0.1`
— and a single new entry point (`SchemaEmit::emit_parse_error`)
that writes one such record into a caller-supplied buffer.

### 15.1 Wire form (v1)

The record is intentionally tiny (32-byte header + token bytes,
padded to 8 bytes) so a consumer can copy it into an audit
frame or a KIND_IPC_ENDPOINT write without a scratch allocator.

|  Offset | Size | Field       | Meaning                            |
|---------|------|-------------|------------------------------------|
|   0     | 8    | magic       | `"PDXAPERR"` ASCII (no NUL)        |
|   8     | 8    | version     | u64 LE; must equal 1               |
|  16     | 4    | err_code    | u32 LE; `ParsedArgs::ERR_*` code   |
|  20     | 4    | argv_index  | u32 LE; `ParsedArgs::error_arg_index` |
|  24     | 4    | token_len   | u32 LE; token bytes to follow      |
|  28     | 4    | token_off   | u32 LE; always 32 in v1            |
|  32     | token_len | token   | verbatim argv-slot bytes, no NUL   |
| next    | 0..7 | padding     | zeros to the next 8-byte boundary  |

Total record = `((32 + token_len + 7) / 8) * 8` bytes.

The wire magic `"PDXAPERR"` sits alongside the sister magics in
this project's wire ecosystem — `PDXARGV\0` (input schema on the
SchemaInvoke path), `PDXAUDIT`, `PDXB` / `PDXL` / `PDXV` (volume
schemas). Eight ASCII characters, no NUL: five body characters
(`APERR` — argv-parse-error) after the mandatory `PDX` trigram.
The magic is stored as a `[u8; 8]` .rodata literal
(`ParseErrorRecord::PERR_MAGIC_BYTES`) and copied into the record
with one `mov rax, [rip + PERR_MAGIC_BYTES]; mov [buf], rax`
pair, mirroring how `HelpBackend::LIT_DDASH` and
`VersionBackend::LIT_NEWLINE` are loaded cross-module.

### 15.2 Module surface delta

New file: `src/parse_error_record.pdx`. Module `ParseErrorRecord`
holds only `.rodata`:

  - `PERR_HEADER_SIZE   : u64      = 32`
  - `PERR_VERSION_V1    : u64      = 1`
  - `PERR_TOKEN_OFFSET  : u64      = 32`
  - `PERR_MAGIC_BYTES   : [u8; 8]  = "PDXAPERR"`
  - `PERR_SCHEMA_NAME_V01 : [u8; 28] = "PdxArgvParseErrorRecord@0.1\0"`

New in `SchemaEmit`:

  - `emit_parse_error(buf, buflen, argv_ptr) -> u64` — leaf,
    all caller-save. Reads `error_code` + `error_arg_index` from
    ParsedArgs; if `error_code == 0` or `buf == 0`, returns 0
    without writing. If `argv_ptr != 0`, derives
    `token_ptr = argv[error_arg_index]` and byte-loops for its
    NUL-terminated length (inlined strlen rather than a
    cross-module call so linking `schema_emit.o` alone still
    resolves). Computes `padded = ((32 + token_len + 7)/8)*8`;
    if `buflen < padded`, returns 0 (no partial write). On
    success writes the 32-byte header (magic qword,
    version qword, four u32 fields via `mov_d`), then copies
    `token_len` bytes into the token region, then zero-fills the
    trailing padding. Returns `padded` in `rax`.

### 15.3 Why a third argument (`argv_ptr`)

The naïve two-argument shape `(buf, buflen)` would require
either a new `ParsedArgs` slot (`error_token_ptr` + a stash pass
inside `parse_argv_fail`) or a global stash — both widen the
parser's write surface for a single-caller value that argv
already carries in the caller's own frame. Passing `argv_ptr`
lets the emitter derive the token via
`argv[error_arg_index]` at emit time with zero parser change,
and it also lets a caller on the SchemaInvoke path (which has
no argv) pass 0 to get a header-only record with
`token_len = 0`. The read is bounded by `error_arg_index` which
the parser already gated against the caller's `argc` — a
consumer that emits from a stale ParsedArgs pointing at a freed
argv gets the same UAF it would from any `flag_names[k]` read;
this is the ambient contract for every pointer this library
stores into ParsedArgs.

### 15.4 token_off = 32 as an explicit field

`token_off` at record offset 28 is always 32 in v1 — the
existing header ends at that offset with no gaps. Emitting it
as an explicit field rather than a magic constant lets a future
v2 grow the header without a wire re-cut: a v2 reader that
finds `token_off > 32` follows the field verbatim; a v1 reader
that finds `token_off != 32` refuses the record. This mirrors
the SchemaInvoke input path's own `header_size` gate at
`ERR_SCHEMA_BAD_LAYOUT`.

### 15.5 What ENH-016 explicitly does not do

- No `flag_id` field in the record. The draft layout in the
  issue text included one; it was dropped because the only
  ERR_* that carries a meaningful flag id today is
  `ERR_UNKNOWN_FLAG`, and in that case the id is 0 by
  construction (FlagSpec::lookup returned FKIND_UNKNOWN, whose
  id sentinel is 0). Consumers wanting the flag id look it up
  themselves via `FlagSpec::lookup(argv[error_arg_index])`; a
  v2 that stores the id inline can grow the header (see §15.4).
- No `reserved` slot. Same rationale as `flag_id` — reserved
  bytes are what `token_off` guards against, so preallocating
  them here is speculative wire real estate that a v2 could
  use better with a purpose-fit field.
- No auto-emit. Unlike `--version` (ENH-032) or `--help`
  (ENH-014) which fire inside `parse_argv` when a well-known
  flag is seen, `emit_parse_error` is opt-in: the consumer's
  own `if err != ERR_OK` branch chooses whether to invoke it.
  Reason: emit_parse_error has no capability of its own to
  write the record anywhere (libpdx-argv holds no fd cap), so
  auto-emitting would produce bytes with nowhere to go.
- No `sys_write` call inside the library. The emitter fills a
  caller-owned buffer; the caller does the transport. Same
  cap posture as `SchemaEmit::get_name` / `get_count`.
- No support for repeated failures. The record captures one
  parse call's outcome. A tool that wants to log every parse
  it did across a long-running session invokes emit_parse_error
  after each `parse_argv` and streams the records itself; the
  library retains nothing across calls.
- No wire-format `PdxArgvParsed@0.1` companion. ENH-003
  withdrew that schema in 2026-08-25; the successful-parse
  wire form remains "callers read `ParsedArgs` in-process".
  A future ENH may add a success-side output schema; ENH-016
  is deliberately failure-only.

## 16. Clustered short-flag expansion (ENH-013, Closes #23)

M1-002 (§5) locked a one-per-hyphen short-flag grammar: any cluster
(`-la`, `-abc`) was rejected with `ERR_CLUSTERED_SHORT` (4). The D3
motivation was correctness — a value-consuming short flag inside a
cluster (`-nX` where `-n` is INT) would silently swallow one of its
neighbours or its value depending on the getopt dialect, and the
semantic-pipe dispatch by id couldn't disambiguate. ENH-013 narrows
the reject to that specific hazard and admits the mainstream
BOOL/COUNTED cluster idiom (`-vv` for verbosity, `-abc` for three
switches).

### 16.1 Admissibility rule

For a cluster `-c1c2...cN` (N ≥ 2), every letter is looked up via
`FlagSpec::lookup`. The cluster is admissible iff for every letter:

- The lookup returns `FKIND_BOOL` (0), **or**
- The lookup returns `FKIND_UNKNOWN` (0xFF) **and** `FlagSpec::strict_mode
  == 0` (permissive) — treated as boolean per M2-001.

Any letter whose lookup returns `FKIND_STR` / `FKIND_INT` /
`FKIND_TIMESPAN` / `FKIND_SIZE` / `FKIND_ENUM` fails the whole
cluster with `ERR_CLUSTER_WITH_ARITY` (16). Strict-mode's ENH-004
rule takes precedence over both branches: an unregistered letter
under `FlagSpec::set_strict(1)` fails with `ERR_UNKNOWN_FLAG` (12).
No letter of a failed cluster is dispatched — `flag_count` is
unchanged from cluster entry.

### 16.2 Two-pass shape

Pass 1 (validation) walks the cluster once, calling
`FlagSpec::lookup` with a 2-byte `cluster_probe` (letter + NUL) as
the name string. Fail-fast on the first offending kind.

Pass 2 (dispatch) walks the cluster again. For each letter it writes
`letter, NUL` into `cluster_scratch_buf[flag_count * 2 ..
flag_count * 2 + 2)` and stores `(name_ptr, 0, id, kind)` into
`flag_names / flag_values / flag_ids / flag_kinds[flag_count]`
under the existing `MAX_FLAGS` overflow gate. The second lookup per
letter is redundant (pass 1 already read the same values) but keeps
the code straight-line — a triple-buffer between passes would trade
lookup cost for scratch-write bookkeeping and read no better.

### 16.3 Scratch buffer sizing

`Parser::cluster_scratch_buf` is 64 bytes = 2 bytes × `MAX_FLAGS`
(32). Because every cluster store increments `flag_count`, and the
overflow gate at `flag_count == 32` fires *before* the 33rd letter's
scratch write, the 64-byte bound is exactly right. `parsed_args_reset`
zeroes `flag_count` so the next parse starts writing at
`scratch[0]`; stale bytes never leak into the current parse because
`flag_names[k]` pointers only reference the freshly-overwritten
2-byte pairs.

`Parser::cluster_probe` is 8 bytes (aligned qword; only its first 2
bytes are used) and is overwritten once per pass-1 letter; it is
never read outside `parse_argv`.

### 16.4 Dispatched-flag observables

An accepted cluster of N letters produces N independent
`ParsedArgs` slots, byte-for-byte identical (up to the name pointer
target) to what typing the N letters space-separated would produce:

- `flag_names[k]` points into `cluster_scratch_buf` (a valid
  NUL-terminated 1-char string); a consumer that reads back the
  raw name gets a 1-byte string. Every plain-single-short
  invocation (`-v -v -v`) puts pointers into argv memory instead;
  the shape (1-char + NUL) is identical.
- `flag_values[k] = 0` (BOOL semantics; cluster-admissible letters
  never consume a value by construction).
- `flag_ids[k]` and `flag_kinds[k]` are set from the lookup return
  (id 0 / kind 0xFF for permissive-mode unregistered letters, per
  M2-001).
- `count_flag_by_id(id) == N` for a `-vvv…N`-length cluster over a
  single BOOL flag — the repeat-count idiom composes with the
  cluster idiom.

### 16.5 What ENH-013 explicitly does not do

- **No auto-emit dispatch from cluster stores.** The ENH-032
  (`--version`) and ENH-014 (`--help`) auto-emit checks that fire
  after every long-flag or single-letter short-flag store are
  deliberately skipped on the cluster expansion path. A tool that
  registers `-h`/`-v` as single-letter shorts with the standard ids
  gets the auto-emit only when the user types them without
  clustering (`-h` alone, not `-vh`). This is outside the
  mainstream `-vvv` idiom and the two-pass expansion would need a
  post-store short-circuit inside the dispatch loop to preserve
  ordering — deferred to a follow-on ENH if any consumer needs it.
- **No new `FKIND_COUNTED` kind.** libpdx-argv's kind space stays
  at BOOL/STR/INT/TIMESPAN/SIZE/ENUM/UNKNOWN. The "COUNTED" idiom
  in the ENH-013 issue is BOOL + `count_flag_by_id` at the read
  side; the parser sees no distinction and needs none.
- **No new registration path.** A cluster-friendly flag is
  registered exactly as any BOOL flag (`flag_spec_register(name,
  FKIND_BOOL, id)`). Existing consumers (StdVocab's `register_all`
  in particular) get cluster support for their BOOL registrations
  without a code change.
- **No cluster-aware diagnostics.** The `ERR_CLUSTER_WITH_ARITY`
  error carries the cluster's `error_arg_index` (the argv slot the
  cluster sits at) but no per-letter offset — a consumer that
  wants to say "letter `b` in `-abc` is the value-consuming one"
  walks the cluster itself. Consistent with every other ERR_*
  code: the parser records where, not why-at-byte-level.
- **No relaxation for the `--=foo`/`--:foo` grammar or any long-
  flag category.** ENH-013 is scoped to the short-flag classifier
  branch only; every other classifier arm is byte-identical to
  pre-ENH-013 behaviour.

Klog tag: `pdxargv.short-cluster`.
