// mayhem/standalone_main.cpp — run-once, file-input driver for the standalone (non-fuzzer)
// reproducer binaries (`<target>-standalone`). This is a corrected copy of RDKit's OWN standalone
// driver (Code/Fuzz/standalone_fuzz_target_runner.cpp, used automatically by Code/Fuzz/CMakeLists.txt
// whenever LIB_FUZZING_ENGINE is unset) — that file fails to compile as shipped (missing
// <cstdint>/<iostream>: `uint8_t` and `std::cout` are undeclared with clang's <fstream>/<vector>
// alone). Rather than patch the upstream file (this integration stays purely additive — see
// mayhem/build.sh), this is a NEW file under mayhem/ with the two missing includes added; everything
// else (including the exact reader logic and console messages) is unchanged from upstream's version.
//
// Original header:
// Copyright 2017 Google Inc. All Rights Reserved.
// Licensed under the Apache License, Version 2.0 (the "License");

#include <cassert>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <vector>

// Forward declare the "fuzz target" interface.
// We deliberately keep this inteface simple and header-free.
extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size);

int main(int argc, char **argv) {
  for (int i = 1; i < argc; i++) {
    std::ifstream in(argv[i]);
    in.seekg(0, in.end);
    size_t length = in.tellg();
    in.seekg(0, in.beg);
    std::cout << "Reading " << length << " bytes from " << argv[i] << std::endl;
    // Allocate exactly length bytes so that we reliably catch buffer overflows.
    std::vector<char> bytes(length);
    in.read(bytes.data(), bytes.size());
    assert(in);
    LLVMFuzzerTestOneInput(reinterpret_cast<const uint8_t *>(bytes.data()),
                           bytes.size());
    std::cout << "Execution successful" << std::endl;
  }
  return 0;
}
