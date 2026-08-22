# libpdx-argv.M2-001 — implementation notes

**Issue:** #3 — typed flag arguments (`--older-than 7d`, `--size > 1MB`)
**Upstream doc:** `design/tooling/r49-r50-plan.md` §5.12 (paideia-os).

## What landed

- `src/flag_spec.pdx` — new `FlagSpec` module. Declarative
  registration table binding a long-flag or short-flag name to a
  value kind (`FKIND_*` constant) and a caller-chosen numeric ID.
  Three entry points:
  - `FlagSpec::reset()` — zero `spec_count` (leaf).
  - `FlagSpec::register(name_ptr, kind, id)` — append at
    `spec_count`; silently drops past `SPEC_MAX = 32` (leaf).
  - `FlagSpec::lookup(name_ptr) -> (kind, id)` — inline strcmp
    against every registered name (leaf; O(SPEC_MAX)). Returns
    `FKIND_UNKNOWN = 0xFF` in `rax` and `id = 0` in `rdx` on miss.
- `src/typed.pdx` — new `Typed` module. Three leaf value parsers
  returning `(ok, val)` via the SysV rax:rdx pair:
  - `Typed::parse_int_u64(str_ptr)` — `[0-9]+` accumulator; `*10`
    via `shl+add` (no `mul`/`imul`, per R49 subset).
  - `Typed::parse_size(str_ptr)` — `[0-9]+` + single-char suffix
    `k`/`K`/`m`/`M`/`g`/`G` → `shl 10`/`20`/`30`.
  - `Typed::parse_timespan(str_ptr)` — `[0-9]+` + single-char suffix
    `s`/`m`/`h`/`d` → `*1`/`*60`/`*3600`/`*86400`, all via
    `shl+add` sequences.
- `src/parsed_args.pdx` — added `flag_kinds` array + `ERR_MISSING_VALUE`
  error code. `find_flag_by_id` helper landed here for M2-002 but is
  cross-cutting: M2-001 uses it in `ParsedArgs::find_flag_by_id`
  documentation, but the primary consumer is M2-002 flags.
- `src/parser.pdx` — major refactor. Parser is now non-leaf: it
  calls `FlagSpec::lookup(name)` once per parsed flag to decide
  whether to consume `argv[i+1]` as the value. Boolean and
  unregistered flags never consume; typed flags always consume
  (or return `ERR_MISSING_VALUE` if no arg is available). Also
  accepts `:` as a value separator alongside `=` (used by
  `--no-cap:KIND_TTY` per I3). Register plan shifts loop state
  into callee-save `rbx/rbp/r12/r13/r14/r15` + 8-byte pad for
  SysV alignment across the nested call. See
  `design/architecture.md` §9.6 for the alignment trace.

## Design decisions

- **Boolean is the safe default for unregistered flags.** The M1
  parser's always-lookahead was the cat-M1 blocker: `cat -n
  foo.txt` bound `foo.txt` to `-n`. M2's `FlagSpec::lookup`
  returns `FKIND_UNKNOWN` for anything not registered; the parser
  treats that identically to `FKIND_BOOL` (no lookahead). Tools
  that need typed short flags register them explicitly.
- **Typed flags consume argv[i+1] unconditionally.** For a typed
  flag with no inline value, the parser takes the next argv entry
  as the value regardless of whether it starts with `-`. This
  matches the standard Unix convention (`grep -e -pattern` binds
  `-pattern` to `-e`). If the value cannot be decoded by the
  chosen `Typed::parse_*`, the consumer diagnoses at value-read
  time — libpdx-argv itself only enforces "the value slot exists".
- **`:` universally accepted as long-flag value separator.** I3's
  `--no-cap:<name>` uses `:`; rather than special-casing that flag
  in the parser, we accept `:` for every long flag. The extra
  syntactic freedom does not hurt any I3 flag (none contains `:`
  in its name) and keeps the walker branchless per byte.
- **Multi-return via SysV rax:rdx pair.** `FlagSpec::lookup` and
  every `Typed::parse_*` return two values (kind+id, or ok+val)
  via `rax` and `rdx`. This is legal SysV and avoids a spill
  slot. Callers must save `rdx` across these calls if they need
  it preserved for other purposes.
- **No `mul`/`imul` in `Typed`.** Both instructions are outside
  the R49 subset per cat's `design/architecture.md` §5 list. The
  parsers use `shl+add` for `*10` and fixed shl+add sequences for
  `*60`/`*3600`/`*86400`. Each sequence has an inline comment
  showing the shift+add decomposition; the largest (86400) is
  five terms.
- **Parser becomes non-leaf.** The single nested call
  (`FlagSpec::lookup`) forces a callee-save prologue. Six pushes +
  `sub rsp, 8` = 7 stack slots after the return address ⇒
  `rsp % 16 == 0` for every nested call.
- **rax carries kind across the store sequence.** After the
  `FlagSpec::lookup` return, `rax = kind` is the value that must
  land in `flag_kinds[k]`. The intervening arity checks
  deliberately do not touch `rax`; the byte loads in the
  well-known `--pdx-schema` compare happen AFTER the store
  sequence (safe to clobber). This saves a spill.

## paideia-as conformance (re-verified)

- Module names PascalCase basename (`FlagSpec`, `Typed`, `Parser`,
  `ParsedArgs`).
- No `test` mnemonic; every zero-check is `cmp reg, 0`.
- Every `cmp reg, imm` uses immediate ≤ 0x7FFFFFFF (max:
  `0xFF` for `FKIND_UNKNOWN`, `32` for the overflow checks,
  single-byte ASCII for character compares, and `0x39` for `'9'`).
- Byte loads always preceded by `xor rax, rax; mov_b rax, [ptr]`
  per the paideia-as #1248 mitigation pattern.
- `r11` used only as scratch (LEA temps for cross-module
  references). Never live across a call.
- No `mul`/`imul`/`neg`/`not`/`inc`/`dec` on general regs. `sub
  reg, imm` is used (dispatch.pdx precedent) for the digit-value
  compute (`sub r8, 0x30`).
- SysV push/pop parity in the parser: 6 callee-save pushes +
  `sub rsp, 8` = aligned `rsp%16 = 0` for every nested call;
  epilogue reverses exactly.

## What did not land (queued for M3+)

- Multi-char size suffixes (`KiB`, `MiB`, `GB`, `MB`) — M3.
- Compound timespans (`1h30m`, `7d12h`) — M3.
- Signed integers, floating-point coefficients — M3.
- Comparison operators (`--size > 1MB` where `>` and `1MB` are
  separate args) — the tool's own DSL layer decodes them; the
  libpdx-argv parser just stores each argv entry as either a
  flag value or a positional.
