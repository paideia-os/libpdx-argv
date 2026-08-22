# libpdx-argv.M2-003 — implementation notes

**Issue:** #5 — positional-argument list handling.
**Upstream doc:** `design/tooling/r49-r50-plan.md` §5.12 (paideia-os).

## What landed

- `src/parsed_args.pdx` — added `ddash_seen : u64` and
  `ddash_arg_index : u64` bookkeeping slots. Reset by
  `ParsedArgs::reset` (extended). Semantics:
  - `ddash_seen == 0` → `--` was never in argv;
    `ddash_arg_index` is undefined.
  - `ddash_seen == 1` → `--` was seen at
    `argv[ddash_arg_index]`; every subsequent argv[j] joined
    `pos_ptrs` regardless of its first byte.
- `src/parser.pdx` — added:
  - A ddash gate at the top of the argv loop: if `ddash_seen ==
    1`, the current arg is routed directly to
    `parse_argv_positional` (bypassing the flag classifier).
  - `parse_argv_set_ddash` label under
    `parse_argv_maybe_long_or_ddash`: when byte2 of an arg is
    NUL (i.e. the arg is exactly `--`), the parser writes
    `ddash_seen = 1` and `ddash_arg_index = i`, then advances
    without adding `--` itself to `pos_ptrs`.

## Design decisions

- **Sentinel is one-shot; there is no `--`-cancel form.** Once
  `ddash_seen == 1`, it stays 1 for the rest of the parse. A
  second `--` in argv becomes a positional (`pos_ptrs[m] = "--"`).
  This is the POSIX / GNU behaviour and matches user expectation.
- **`--` itself is NOT stored as a positional.** Its role is
  metadata. Consumers that need to see it can reconstruct via
  `argv[ddash_arg_index]`; tools that just want the file list
  read `pos_ptrs[0..pos_count]`.
- **`ddash_arg_index` uses `0` as an unsafe sentinel for "unseen".**
  The consumer must check `ddash_seen == 1` before trusting
  `ddash_arg_index`. This is why they are two slots and not a
  packed word.
- **Overflow discipline unchanged.** A positional that pushes
  `pos_count` past 32 still returns `ERR_POS_OVERFLOW`. The
  ddash gate does not raise the cap; a `rm a b c ... (33 args)`
  still fails at the 33rd. Raising `MAX_POS` is a queued M4+
  concern (some tools may need 1024+ positionals).

## paideia-as conformance

- Every new immediate is `0`, `1`, or a single-byte char code —
  well within the ≤ 0x7FFFFFFF constraint.
- The ddash-gate reads `ddash_seen` on every loop iteration;
  this is a `lea r11, [rip + ...]; mov rax, [r11]; cmp rax, 0`
  three-instruction sequence executed once per argv entry. Cheap
  enough to leave in-line rather than hoist.

## What did not land (queued for M3+ / M4)

- Raise `MAX_POS` above 32 for tools that handle many
  positionals (`grep pattern *.pdx` under a large tree, `pkg
  install foo bar baz ...`). The current 32-slot ceiling was
  set at M1 for hand-audit surface; the M4 test matrix will
  drive the decision.
- Extra bookkeeping for "positionals per source" — pre-ddash vs
  post-ddash slices. Consumers that care today can compare each
  positional's argv index against `ddash_arg_index`; a native
  slice API is M3+ ergonomics.
