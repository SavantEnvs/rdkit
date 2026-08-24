#!/usr/bin/env bash
#
# mayhem/test.sh — RUNS 3 of RDKit's own C++ unit-test binaries (already built by mayhem/build.sh
# into build-tests/bin/, with the project's NORMAL flags — a separate, clean build from the sanitized
# fuzz build). Never compiles here. Behavioral, not "did it crash": each binary calls RDKit's
# TEST_ASSERT() macro (Code/RDGeneral/Invariant.h), which throws Invar::Invariant on a failed check —
# an uncaught C++ exception, so the process aborts (nonzero exit) on ANY assertion failure. A neutered
# parser (e.g. SmilesToMol always returning null, or a pickle round-trip that silently drops atoms)
# fails these for real; "ran without crashing" is not the oracle here.
#
#   smiTest2         (Code/GraphMol/SmilesParse/test2.cpp)     -> exercises SmilesParse — same code
#                     path as the smiles_string_to_mol_fuzzer target.
#   fileParsersTest1  (Code/GraphMol/FileParsers/test1.cpp)    -> exercises FileParsers' Mol-block/
#                     query parsing — same code path as mol_data_stream_to_mol_fuzzer.
#   graphmoltestPickler (Code/GraphMol/testPickler.cpp)        -> exercises MolPickler round-trips —
#                     same code path as mol_deserialization_fuzzer.
# (RDKit's full C++ suite is thousands of cases across every subsystem — out of scope for a PATCH-tier
# oracle; these 3 are the ones that actually cover the 3 fuzz harnesses shipped here.)
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "${SRC:-/mayhem}"
export RDBASE="${SRC:-/mayhem}"

emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# Each entry: name : binary path : a substring that ONLY appears in the binary's own log output once
# its real test logic has actually run (not just "process exited 0"). This is what makes the oracle
# behavioral rather than exit-status-only: verify-repo's anti-reward-hack sabotage check LD_PRELOADs a
# constructor that _exit(0)s the binary before main() runs anything — that still gives exit code 0
# with EMPTY output, so a marker-in-output check catches it even though a bare `if "$bin"` would not.
TESTS=(
  "smiTest2:build-tests/Code/GraphMol/SmilesParse/smiTest2:Failed parsing SMILES 'CO'"
  "fileParsersTest1:build-tests/Code/GraphMol/FileParsers/fileParsersTest1:generating smiles"
  "graphmoltestPickler:build-tests/Code/GraphMol/graphmoltestPickler:Testing boost::serialization integration"
)

passed=0; failed=0
for entry in "${TESTS[@]}"; do
  t="${entry%%:*}"
  rest="${entry#*:}"
  bin="${rest%%:*}"
  marker="${rest#*:}"
  if [ ! -x "$bin" ]; then
    echo "test.sh: $bin missing — build.sh must build it (not rebuilding here)" >&2
    failed=$((failed+1))
    continue
  fi
  echo "== running $t =="
  out="$("$bin" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ] && grep -qF "$marker" <<<"$out"; then
    echo "  ok   - $t"
    passed=$((passed+1))
  else
    echo "  FAIL - $t (exit $rc, marker '$marker' seen: $(grep -qF "$marker" <<<"$out" && echo yes || echo no))"
    failed=$((failed+1))
  fi
done

echo "test.sh: passed=$passed failed=$failed"
emit_ctrf rdkit-ctest "$passed" "$failed"
