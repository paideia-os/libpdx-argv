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
- `Parser` (`src/parser.pdx`) — one entry point:
  `parse_argv(argv_ptr: u64, argc: u64) -> u64`.

The consumer wires libpdx-argv into its own tool as follows:

```
ParsedArgs::reset()
let err = Parser::parse_argv(argv, argc)
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

## 5. Short-flag rejection contract (M1-002)

When byte1 is neither `'-'` nor NUL, the arg is a short flag. D3 in
`design/tooling/plan.md` mandates one-flag-per-hyphen; `-la` is a
category error, not a two-flag shorthand.

**Accepted:** `-f` — a single letter followed by NUL. Stored as
`flag_names[k] = "f\0"` (interior pointer just past the `-`),
`flag_values[k] = 0`. If the next argv element does not start with `-` or
NUL, it is consumed as the value (mirrors the long-flag lookahead rule
above). Short flags do not participate in the `--pdx-schema` well-known
compare — that flag is long-only.

**Rejected:** `-la` — a two-or-more-character run after the `-`. Sets
`ERR_CLUSTERED_SHORT`. The parser stops before this arg is stored, and
the erroring `argv[i]` is discoverable via the
`ParsedArgs::error_arg_index` slot the parser writes alongside every
error-code write (see `parse_argv_fail` in `src/parser.pdx`).

D3 justification: the GNU behaviour of clustering (`ls -la` == `ls -l -a`)
lets a typo like `-lat` silently activate a third flag `-t` the user did
not intend. The paideia-os shell renders short-flag rejection with a
one-line diagnostic that suggests the two-hyphen form and offers to
retry.

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
FlagSpec::reset()                        // clear the table
FlagSpec::register(name_ptr, kind, id)   // append (name, kind, id)
FlagSpec::lookup(name_ptr) -> (kind, id) // rax = kind, rdx = id
```

`register` silently drops past `SPEC_MAX = 32`; callers that need
overflow detection compare `spec_count` against `SPEC_MAX` before the
call. `lookup` is a linear scan (O(SPEC_MAX)) with an inline strcmp;
one call per parsed flag.

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

**Preconditions.** `ParsedArgs::reset()` and `FlagSpec` registration
must have happened before the call. The consumer's `_start` sequence
becomes:

```
FlagSpec::reset()
StdVocab::register_all()
FlagSpec::register(tool_specific ...)
ParsedArgs::reset()

if invoked_via_argv:
    Parser::parse_argv(argv, argc)
else:                                # invoked via semantic-pipe
    SchemaInvoke::parse_from_schema_record(rec_ptr, rec_len)

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
| 1  | `ParseGrammarTests` (parse_grammar.pdx)  | 16 |
| 2  | `ParseTypedValuesTests` (parse_typed_values.pdx) | 17 |
| 3  | `ParseTypedArgsTests` (parse_typed_args.pdx) | 5  |
| 4  | *reserved* (parse_positional_ext)         | —  |
| 5  | `ParseStdVocabTests` (parse_std_vocab.pdx) | 2  |
| 6  | `ParseSchemaRecordTests` (parse_schema_record.pdx) | 10 |
| 7  | `HelpBackendTests` (help_backend.pdx)     | 3  |
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
