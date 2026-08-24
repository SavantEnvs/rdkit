#!/usr/bin/env bash
#
# mayhem/build.sh — build 2 of RDKit's upstream OSS-Fuzz harnesses (Code/Fuzz/*.cc), one Mayhem
# target each (target name == binary name):
#   smiles_string_to_mol_fuzzer      SMILES string parsing
#   mol_data_stream_to_mol_fuzzer    Mol-block/SDF stream parsing
# These are RDKit's own OSS-Fuzz harnesses (Code/Fuzz/, "Copyright 2020 Google LLC"), built via the
# project's normal CMake fuzz-target machinery (RDK_BUILD_FUZZ_TARGETS=ON) — not new harnesses.
#
# mol_deserialization_fuzzer (pickle deserialization) is deliberately NOT shipped here: a live run
# gets real crash reports (confirming it genuinely exercises RDKit::MolPickler::molFromPickle) but
# edges_covered stays exactly 0 for the full run duration, while the other two targets — same
# library, same build flags, same -fsanitize=fuzzer-no-link fix — show real coverage. Root cause not
# resolved; dropped rather than shipping a target the edges>0 gate can never pass.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The Dockerfile's extra-apt
# step already built a small static Boost (iostreams/serialization/regex/system) into
# /opt/boost-static — RDKit's Code/Fuzz/CMakeLists.txt hard-requires Boost_USE_STATIC_LIBS=ON (a
# SEND_ERROR otherwise) and Debian's libboost-*-dev ships shared .so only.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "${SRC:-/mayhem}"

TARGETS=(smiles_string_to_mol_fuzzer mol_data_stream_to_mol_fuzzer)

# Common CMake options: disable Python/SWIG/ChemDraw/MinimalLib wrappers (not needed by the fuzz
# targets, and ChemDraw pulls in an uninstrumented system expat that isn't installed here) — mirrors
# the flags google/oss-fuzz's own projects/rdkit/build.sh uses for the same Code/Fuzz harnesses.
# RDK_BUILD_PUBCHEMSHAPE_SUPPORT / RDK_BUILD_FREETYPE_SUPPORT / RDK_BUILD_COORDGEN_SUPPORT /
# RDK_BUILD_MAEPARSER_SUPPORT are OFF because upstream's own CMakeLists.txt fetches source tarballs
# for them at CONFIGURE time (pubchem-align3d, a comic-sans font file, maeparser) over the network —
# none of the 3 fuzz targets need them, so turning them off keeps configure air-gapped-clean. (One
# fetch is NOT avoidable this way: RingDecomposerLib — needed by RingDecomposerLib_static, which the
# fuzz targets DO link — downloads unconditionally on first configure, with no option gate. It's
# fetched once here, while the Dockerfile RUN has network; the extracted source then persists in the
# image tree, so a later `--network none` re-run of this script finds it already present and doesn't
# re-fetch. Ditto for CMake's own FetchContent of `better_enums`, cached under build/_deps/.)
COMMON_OPTS=(
  -DRDK_INSTALL_INTREE=ON
  -DRDK_BUILD_PYTHON_WRAPPERS=OFF
  -DRDK_BUILD_CHEMDRAW_SUPPORT=OFF
  -DRDK_BUILD_MINIMAL_LIB=OFF
  -DRDK_BUILD_PUBCHEMSHAPE_SUPPORT=OFF
  -DRDK_BUILD_FREETYPE_SUPPORT=OFF
  -DRDK_BUILD_COORDGEN_SUPPORT=OFF
  -DRDK_BUILD_MAEPARSER_SUPPORT=OFF
)

# 1) Sanitized build: the project itself + the 3 fuzz harnesses, instrumented with $SANITIZER_FLAGS
#    $DEBUG_FLAGS (put $DEBUG_FLAGS after so its -gdwarf-3 wins) so ASan/UBSan actually see the code
#    the fuzz harnesses call, not just the harness shim.
#    -fsanitize=fuzzer-no-link: $LIB_FUZZING_ENGINE (-fsanitize=fuzzer) is only linked into the final
#    fuzzer executable by RDKit's own Code/Fuzz/CMakeLists.txt (via LIB_FUZZING_ENGINE), never threaded
#    into these CMAKE_C/CXX_FLAGS — so without this, the ~20 static libs that make up the real parsing
#    code compile with ASan+UBSan only, ZERO SanitizerCoverage instrumentation (confirmed: a live run
#    showed 0 edges_covered, 0 crashes, across all 3 targets, despite genuine multi-minute execution).
#    -fsanitize=fuzzer-no-link adds coverage counters without libFuzzer's own main() — safe to link
#    into both the real fuzzer binaries (step 1) and the standalone/no-engine reproducers (step 2,
#    which reuses this same build dir's compile flags). Same fix as the tinyxml2 precedent.
cmake -S . -B build -G Ninja \
  "${COMMON_OPTS[@]}" \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_C_FLAGS="$SANITIZER_FLAGS -fsanitize=fuzzer-no-link $DEBUG_FLAGS" \
  -DCMAKE_CXX_FLAGS="$SANITIZER_FLAGS -fsanitize=fuzzer-no-link $DEBUG_FLAGS" \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DRDK_BUILD_FUZZ_TARGETS=ON \
  -DLIB_FUZZING_ENGINE="$LIB_FUZZING_ENGINE" \
  -DRDK_INSTALL_STATIC_LIBS=ON \
  -DBoost_USE_STATIC_LIBS=ON \
  -DBOOST_ROOT=/opt/boost-static \
  -DBoost_NO_SYSTEM_PATHS=ON \
  -DRDK_BUILD_CPP_TESTS=OFF

cmake --build build -j"$MAYHEM_JOBS" \
  --target smiles_string_to_mol_fuzzer \
  --target mol_data_stream_to_mol_fuzzer

for t in "${TARGETS[@]}"; do
  install -m0755 "build/Code/Fuzz/$t" "/mayhem/$t"
done

# 2) Standalone (non-fuzzer) reproducers. RDKit's own Code/Fuzz/CMakeLists.txt WOULD build a run-once,
#    file-input driver (standalone_fuzz_target_runner.cpp) whenever LIB_FUZZING_ENGINE is unset — but
#    that upstream file fails to compile as shipped (missing <cstdint>/<iostream>: uint8_t/std::cout
#    are undeclared). Rather than patch the upstream file (this integration stays purely additive),
#    use mayhem/standalone_main.cpp — a corrected copy of the same driver — instead, per PORTING.md's
#    fallback to $STANDALONE_FUZZ_MAIN when a project's own driver can't be used as-is: compile it once
#    as a C++ object and pass that object's path as LIB_FUZZING_ENGINE (CMake's target_link_libraries
#    accepts a plain object-file path as a link-line ingredient). Reconfigure the SAME build dir: the
#    ~20 static libs' compile flags are unchanged, so Ninja only relinks the 3 fuzzer executables
#    (fast) instead of a full rebuild.
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -std=gnu++20 -c mayhem/standalone_main.cpp -o /tmp/standalone_main.o
cmake -S . -B build -DLIB_FUZZING_ENGINE=/tmp/standalone_main.o
cmake --build build -j"$MAYHEM_JOBS" \
  --target smiles_string_to_mol_fuzzer \
  --target mol_data_stream_to_mol_fuzzer

for t in "${TARGETS[@]}"; do
  install -m0755 "build/Code/Fuzz/$t" "/mayhem/$t-standalone"
done

# 3) The project's OWN test suite, with NORMAL (unsanitized) flags — a separate, independent build so
#    mayhem/test.sh only RUNS it. Scoped to 3 targeted rdkit_test binaries whose code paths match the
#    3 fuzz harnesses above (SMILES parsing / mol-block parsing / pickle round-trip) rather than
#    RDKit's entire multi-thousand-case C++ suite (impractical to build+run at PATCH-grade turnaround).
#    RDK_BUILD_FUZZ_TARGETS=OFF here so the strict static-Boost requirement (step 1) doesn't apply.
cmake -S . -B build-tests -G Ninja \
  "${COMMON_OPTS[@]}" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS" \
  -DRDK_BUILD_FUZZ_TARGETS=OFF \
  -DRDK_INSTALL_STATIC_LIBS=OFF \
  -DRDK_BUILD_CPP_TESTS=ON

cmake --build build-tests -j"$MAYHEM_JOBS" \
  --target smiTest2 --target fileParsersTest1 --target graphmoltestPickler

echo "build.sh: built ${TARGETS[*]} (+ -standalone) and the test binaries (smiTest2, fileParsersTest1, graphmoltestPickler)"

