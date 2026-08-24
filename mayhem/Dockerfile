# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile (SMALL form, PREFERRED) — builds ON TOP of the org C/C++ base
# image (ghcr.io/savantenvs/base). The base already provides debian + clang/llvm +
# libFuzzer/afl++ + the identities + the build-contract ENV, so this only adds the
# per-commit build (built on top of the prebuilt base, rather than building the toolchain in-image).
#
# Build (from the repo root):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) \
#       [--build-arg SOURCE_DATE_EPOCH=$(date +%s)] \
#       -t mytag .

# The org base, pinned to a fixed DATE-tagged base (YYYYMMDD; shared by all integrations
# minted against it). Use the current dated tag; pin by digest in production: ...base@sha256:<digest>.
FROM ghcr.io/savantenvs/base:20260621

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (available to build.sh); do NOT bake it as an ENV — an
# empty value breaks clang ("must be a non-negative decimal integer") both here and for
# any in-image rebuild. build.sh unsets it when empty.
ARG SOURCE_DATE_EPOCH

# Sanitizer override: the base exports SANITIZER_FLAGS (ASan+UBSan, halting) as the default.
# To change it for a build (e.g. ASan-only, or add MSan): --build-arg SANITIZER_FLAGS="...".
# Declare it WITHOUT a default (no '='): an undefaulted ARG lets the base ENV flow through to
# build.sh when not passed, and an explicit --build-arg overrides it. (An empty default — `=` —
# would instead shadow the base ENV and silently wipe the sanitizers.)
ARG SANITIZER_FLAGS
# Coverage (optional, off by default): instrument the TEST build to measure how much of the project
# the suite exercises — --build-arg COVERAGE_FLAGS="-fprofile-instr-generate -fcoverage-mapping".
# Empty by default (no effect on the normal oracle build); build.sh appends it to the test build only.
ARG COVERAGE_FLAGS=
# Build parallelism (optional). build.sh falls back to nproc when unset: --build-arg MAYHEM_JOBS=8
ARG MAYHEM_JOBS=

# RDKit needs Eigen3 (RDK_BUILD_DESCRIPTORS3D) and Catch2 v3 (RDKit's own top-level CMakeLists.txt
# unconditionally does find_package(Catch2 3)/FetchContent regardless of RDK_BUILD_CPP_TESTS) as
# system packages — this lets CMake's find_package() succeed and skip its own network
# FetchContent/ExternalProject_Add fetches (better_enums and RingDecomposerLib are still fetched
# once, at image build time when the network IS available — see mayhem/build.sh; the extracted
# source persists in the image tree, so a later offline re-run of build.sh finds it already there).
USER root
RUN [ -n "$SOURCE_DATE_EPOCH" ] && repro-sources-list.sh || true ; \
    apt-get update && apt-get install -yq --no-install-recommends \
      libeigen3-dev libcatch2-dev wget \
 && rm -rf /var/lib/apt/lists/*

# RDKit's Code/Fuzz/CMakeLists.txt hard-requires Boost_USE_STATIC_LIBS=ON (a fatal error otherwise:
# "Fuzzing requires static linking!"), but Debian's libboost-*-dev packages ship shared .so only (no
# .a). Build the small set of Boost components the fuzz build actually needs (iostreams,
# serialization, regex, system — RDK_USE_BOOST_IOSTREAMS/RDK_USE_BOOST_SERIALIZATION, both default
# ON) from source, static, into /opt/boost-static — the same approach google/oss-fuzz's own
# projects/rdkit/build.sh uses (they build Boost from source too, for the same reason, just with the
# clang toolset to dodge an MSan-only ABI issue that doesn't apply to our ASan+UBSan-only build).
RUN cd /tmp && \
    wget -q https://archives.boost.io/release/1.84.0/source/boost_1_84_0.tar.bz2 && \
    tar xf boost_1_84_0.tar.bz2 && \
    cd boost_1_84_0 && \
    ./bootstrap.sh --with-libraries=iostreams,serialization,regex,system --prefix=/opt/boost-static && \
    ./b2 -q -j"$(nproc)" link=static variant=release cxxflags="-fPIC" install >/tmp/b2.log 2>&1 && \
    cd / && rm -rf /tmp/boost_1_84_0*
USER mayhem

# Source enters from the build CONTEXT (the CI checkout): the FULL repo (incl. .git
# history) is copied to /mayhem as `mayhem`; build.sh builds in place.
USER mayhem
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

RUN bash mayhem/build.sh

# Run the project's functional tests at build time IF the repo ships them (mayhem/test.sh is
# optional — omit it only when the repo has no tests meaningful for RL). A failing suite fails the
# image build, so the commit image is guaranteed to build AND pass its own tests.
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh — repo ships no functional tests"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
