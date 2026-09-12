#!/usr/bin/env bash
# tools/run-tests.sh — libpdx-argv.ENH-007 (Closes #14)
#
# Real end-to-end test runner. Assembles src/*.pdx + tests/*.pdx via
# paideia-as, links the smoke ELF against tests/sys_exit_shim.pdx and
# `tools/tests-link.ld`, execs it on the host (paideia-os SC+ IDs 1
# and 60 are Linux-compatible by design — see
# `tests/sys_exit_shim.pdx` module preamble), and decodes the packed
# (pass_count << 16) | fail_count exit code.
#
# Pre-ENH-007 the repo had NO runner: every "smoke passes" claim in
# STATUS.md / tests/README.md / design/architecture.md was actually a
# claim that each `.pdx` file assembled cleanly, not that the smoke
# executed. See STATUS.md §"Runnable smoke wiring" for the plainly-
# stated pre-1.1 provenance.
#
# Exit-code contract
# ------------------
# The smoke driver packs its tally as `(pass_count << 16) | fail_count`
# and calls SysExit::exit(code). The paideia-os SC+ 60 dispatch (and
# Linux sys_exit at syscall 60, same table) preserves the full 32-bit
# `status` word in the kernel's task_struct; a shell reading `$?` on
# the parent side sees only the low 8 bits (WEXITSTATUS). Fortunately
# 50 test cases → fail_count fits inside those 8 bits, so `$? == 0`
# on all-green and `$? == N` on N failures is a reliable pass/fail
# signal without needing waitid.
#
# For the full pass_count decode we prefer python3's os.waitid (fills
# siginfo_t.si_status with the raw 32-bit int the child passed) when
# available. If python3 is missing the wrapper falls back to `$?` and
# reports fail_count only (annotating that pass_count could not be
# recovered).
#
# Success shape (clean tree, 50/50):
#   [run-tests] linking build-out/pdxargv_smoke.elf
#   [run-tests] executing build-out/pdxargv_smoke.elf
#   [run-tests] exit status = 0x00320000 (pass=50 fail=0)
#   PDXARGV SMOKE OK
#
# Failure shape (one broken assertion in parse_grammar_tests):
#   [run-tests] exit status = 0x00310001 (pass=49 fail=1) last_fail_tag high dword=1
#   PDXARGV SMOKE FAIL
#
# Wrapper exit codes
#   0    smoke ran clean, PDXARGV SMOKE OK
#   1    build (paideia-as assemble) failed
#   2    link stage failed (see stderr for the ld diagnostic)
#   3    smoke ran but reported fail_count > 0 (PDXARGV SMOKE FAIL)
#   4    smoke was killed by a signal (segfault etc.) — the raw wait
#        status is printed for triage
#   5    prerequisite missing (paideia-as, ld) — see stderr
#
# Usage
# -----
#   bash tools/run-tests.sh              # default: build + link + run
#   bash tools/run-tests.sh --no-run     # build + link only, skip exec
#   bash tools/run-tests.sh --keep-elf   # do not delete the smoke ELF
#                                        # after run (default: keep;
#                                        # flag reserved for future
#                                        # --delete-on-pass behaviour)

set -uo pipefail
# NB: we deliberately do NOT set -e — the wrapper wants to observe
# non-zero exits from every stage and translate them into the
# categorised exit codes above.

cd "$(dirname "$0")/.."

# ---------------------------------------------------------------------
# Argument parsing (minimal — extend as ENH-007 follow-ups warrant).
# ---------------------------------------------------------------------
RUN_SMOKE=1
while [ "$#" -gt 0 ]; do
    case "$1" in
        --no-run) RUN_SMOKE=0; shift ;;
        --keep-elf) shift ;;  # accepted, currently a no-op (see header)
        -h|--help)
            sed -n '/^# tools\/run-tests\.sh/,/^set -uo pipefail/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "[run-tests] FAIL: unknown arg '$1' (see --help)" >&2
            exit 5
            ;;
    esac
done

# ---------------------------------------------------------------------
# Resolve paideia-as via the same shape tools/build.sh uses. Kept in
# lockstep so a repo-local override (env PAIDEIA_AS) affects both.
# ---------------------------------------------------------------------
MIN_VERSION="0.21.0"

resolve_paideia_as() {
    if [ -n "${PAIDEIA_AS:-}" ] && [ -x "$PAIDEIA_AS" ]; then
        echo "$PAIDEIA_AS"; return
    fi
    for cand in \
        "../paideia-os/tools/paideia-as/target/release/paideia-as" \
        "$HOME/Development/PaideiaOS/tools/paideia-as/target/release/paideia-as"
    do
        if [ -x "$cand" ]; then
            echo "$cand"; return
        fi
    done
    if command -v paideia-as >/dev/null 2>&1; then
        command -v paideia-as; return
    fi
    return 1
}

version_ge() {
    printf '%s\n%s\n' "$2" "$1" | sort -V -C
}

PA="$(resolve_paideia_as || true)"
if [ -z "$PA" ]; then
    echo "[run-tests] FAIL: paideia-as not found. Set PAIDEIA_AS or clone paideia-os as a sibling." >&2
    exit 5
fi
VER="$("$PA" --version | awk '{print $2}')"
if ! version_ge "$VER" "$MIN_VERSION"; then
    echo "[run-tests] FAIL: paideia-as $VER is too old, need >= $MIN_VERSION (found $PA)" >&2
    exit 5
fi
echo "[run-tests] paideia-as $VER at $PA"

# ---------------------------------------------------------------------
# ld sanity — the linker is a hard prereq for the smoke ELF.
# ---------------------------------------------------------------------
LD="${LD:-ld}"
if ! command -v "$LD" >/dev/null 2>&1; then
    echo "[run-tests] FAIL: '$LD' not on \$PATH. Install binutils or set LD." >&2
    exit 5
fi

BUILD_DIR="build-out"
mkdir -p "$BUILD_DIR"

# ---------------------------------------------------------------------
# Stage 1: assemble every src/*.pdx + tests/*.pdx.
# tests/sys_exit_shim.pdx participates on this pass (it is a normal
# tests/*.pdx from paideia-as's point of view).
# ---------------------------------------------------------------------
echo "[run-tests] stage 1: paideia-as build"

FAIL=0
COUNT=0
SRC_OBJECTS=()
TEST_OBJECTS=()

assemble_one() {
    local pdx="$1" prefix="$2" out_array="$3"
    local obj="$BUILD_DIR/${prefix}$(basename "$pdx" .pdx).o"
    COUNT=$((COUNT + 1))
    if ! "$PA" build --emit elf64 "$pdx" -o "$obj" 2>&1; then
        FAIL=$((FAIL + 1))
        return
    fi
    eval "$out_array+=('$obj')"
}

for pdx in src/*.pdx; do
    [ -f "$pdx" ] || continue
    assemble_one "$pdx" "" SRC_OBJECTS
done

if [ -d tests ]; then
    for pdx in tests/*.pdx; do
        [ -f "$pdx" ] || continue
        assemble_one "$pdx" "tests-" TEST_OBJECTS
    done
fi

echo "[run-tests] stage 1: $COUNT source(s), $FAIL failure(s)"
if [ "$FAIL" -ne 0 ]; then
    echo "[run-tests] FAIL: paideia-as build stage failed; smoke not linked" >&2
    exit 1
fi

# ---------------------------------------------------------------------
# Stage 2: link the smoke ELF.
#
# Link line: every src/*.o (library body) + every tests/*.o (fixture
# modules + harness + driver + sys_exit_shim). tools/tests-link.ld
# supplies the section layout.
#
# Known link hazard the runner exposes (not swallows): every test
# module currently exports `run_case1`, `run_case2`, ... as bare flat
# linker symbols (paideia-as elaborator flattens `Module::fn` path
# references to the last segment — see
# paideia-as::parse_stmt::try_extract_symbol_name comment, issue
# #1319). `run_case1` therefore appears in six of the seven test
# objects, and ld -z defs (the default) will emit a duplicate-symbol
# error. The runner does NOT pass --allow-multiple-definition — a
# silent "first-wins" resolution would let the smoke report green
# after running each `run_case1` only once, which is worse than a
# categorical link failure. Escalate to paideia-as for Module::fn
# mangling (or in-repo rename the test cases to
# <module>_<case> shape) to unblock end-to-end execution. This
# runner is correct as it stands — the link failure it surfaces is
# the newly-visible truth of the smoke wiring's coverage.
# ---------------------------------------------------------------------
SMOKE_ELF="$BUILD_DIR/pdxargv_smoke.elf"
echo "[run-tests] stage 2: link -> $SMOKE_ELF"

# Depending on ld's front-end version, --gc-sections may prune the
# .text._start emitted by SmokeDriver::_start if it does not see it
# as a KEEP root. The linker script's ENTRY(_start) + KEEP(*(.text._start))
# both cover this.
LINK_LOG="$BUILD_DIR/link.log"
if ! "$LD" -nostdlib --warn-common --fatal-warnings --gc-sections \
    -T tools/tests-link.ld \
    -o "$SMOKE_ELF" \
    "${SRC_OBJECTS[@]}" "${TEST_OBJECTS[@]}" \
    2> "$LINK_LOG"
then
    echo "[run-tests] FAIL: ld returned non-zero — see $LINK_LOG" >&2
    echo "---- link stderr (tail) ----" >&2
    tail -40 "$LINK_LOG" >&2
    echo "----------------------------" >&2
    # Categorise duplicate-symbol errors so downstream tooling can grep
    # for the known paideia-as gap without regex-scraping the log.
    if grep -q "multiple definition of" "$LINK_LOG"; then
        echo "[run-tests] diagnostic: duplicate flat linker symbols across test modules." >&2
        echo "[run-tests] diagnostic: paideia-as elaborator flattens Module::fn to the last" >&2
        echo "[run-tests] diagnostic: path segment (see parse_stmt::try_extract_symbol_name," >&2
        echo "[run-tests] diagnostic: issue #1319). Escalate: add module-qualified symbol" >&2
        echo "[run-tests] diagnostic: mangling in paideia-as OR rename test cases in-repo to" >&2
        echo "[run-tests] diagnostic: <module>_<case> shape (e.g. parse_grammar_run_case1)." >&2
    fi
    exit 2
fi
echo "[run-tests] stage 2: link OK -> $SMOKE_ELF"

if [ "$RUN_SMOKE" -eq 0 ]; then
    echo "[run-tests] --no-run: build+link complete; skipping exec"
    exit 0
fi

# ---------------------------------------------------------------------
# Stage 3: exec the smoke ELF and decode its 32-bit exit status.
# ---------------------------------------------------------------------
echo "[run-tests] stage 3: executing $SMOKE_ELF"

# Prefer python3 for full waitid-based 32-bit status recovery.
RAW_STATUS=""
if command -v python3 >/dev/null 2>&1; then
    RAW_STATUS="$(python3 - "$SMOKE_ELF" <<'PY'
import os, sys
elf = sys.argv[1]
pid = os.fork()
if pid == 0:
    try:
        os.execv(elf, [elf])
    except OSError as e:
        os._exit(126)
info = os.waitid(os.P_PID, pid, os.WEXITED)
# si_code: CLD_EXITED=1, CLD_KILLED=2, CLD_DUMPED=3
if info.si_code == 1:
    # Normal exit — si_status is the full int the child passed to exit_group.
    print(f"exited {info.si_status & 0xFFFFFFFF}")
else:
    print(f"signaled {info.si_status} code {info.si_code}")
PY
    2>&1)"
    PY_RC=$?
    if [ "$PY_RC" -ne 0 ]; then
        echo "[run-tests] python3 waitid helper failed (rc=$PY_RC): $RAW_STATUS" >&2
        RAW_STATUS=""
    fi
fi

if [ -z "$RAW_STATUS" ]; then
    # Fallback: exec directly and read $? (low 8 bits only — fail_count only).
    "$SMOKE_ELF"
    LOW8=$?
    if [ "$LOW8" -eq 139 ] || [ "$LOW8" -eq 134 ] || [ "$LOW8" -eq 137 ]; then
        # 128+signal shape from bash for a signalled child.
        echo "[run-tests] smoke killed by signal (bash exit=$LOW8)" >&2
        echo "PDXARGV SMOKE FAIL"
        exit 4
    fi
    # Low 8 bits are fail_count (0 == pass). pass_count not recoverable.
    if [ "$LOW8" -eq 0 ]; then
        echo "[run-tests] exit status = ?? (pass=? fail=0) [python3 unavailable — full 32-bit tally not decoded]"
        echo "PDXARGV SMOKE OK"
        exit 0
    else
        echo "[run-tests] exit status = ?? (pass=? fail=$LOW8) [python3 unavailable]"
        echo "PDXARGV SMOKE FAIL"
        exit 3
    fi
fi

# Parse the python3 helper's one-line output.
case "$RAW_STATUS" in
    "exited "*)
        STATUS_INT="${RAW_STATUS#exited }"
        STATUS_HEX=$(printf '0x%08x' "$STATUS_INT")
        # (pass_count << 16) | fail_count — mask 16-bit fields.
        PASS_COUNT=$(( (STATUS_INT >> 16) & 0xFFFF ))
        FAIL_COUNT=$(( STATUS_INT & 0xFFFF ))
        echo "[run-tests] exit status = $STATUS_HEX (pass=$PASS_COUNT fail=$FAIL_COUNT)"
        if [ "$FAIL_COUNT" -eq 0 ] && [ "$PASS_COUNT" -gt 0 ]; then
            echo "PDXARGV SMOKE OK"
            exit 0
        else
            # last_fail_tag lives in the smoke ELF's .bss (harness.pdx
            # TestHarness::last_fail_tag). Reading it post-exec would
            # require a debugger; the tally alone tells us fail_count
            # and (indirectly, via pass_count position) which module
            # was reached — sufficient for a first-cut diagnostic.
            echo "PDXARGV SMOKE FAIL"
            exit 3
        fi
        ;;
    "signaled "*)
        echo "[run-tests] smoke killed by signal: $RAW_STATUS" >&2
        echo "PDXARGV SMOKE FAIL"
        exit 4
        ;;
    *)
        echo "[run-tests] unexpected python3 helper output: $RAW_STATUS" >&2
        echo "PDXARGV SMOKE FAIL"
        exit 4
        ;;
esac
