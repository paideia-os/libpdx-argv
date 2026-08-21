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
