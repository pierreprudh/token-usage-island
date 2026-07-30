#!/bin/bash
# Build and run the test suite. Compiles Sources/{Data,IslandView}.swift plus all
# of Tests/ into a single binary and runs it. The test files use a tiny custom
# harness (Tests/TestRunner.swift) because the shipping toolchain on this project
# doesn't include XCTest and Swift Testing's `_TestingInternals` lookup is broken.
#
# Usage: ./test.sh            — build + run
#        ./test.sh --no-build — run the existing build/TokenUsageIslandTests
#
# The exit code is the test runner's exit code (0 = all green, 1 = failures).

set -euo pipefail
cd "$(dirname "$0")"

BUILD="build/TokenUsageIslandTests"
TARGET="arm64-apple-macos14.0"

if [ "${1:-}" != "--no-build" ]; then
    mkdir -p build
    swiftc -O \
        -o "$BUILD" \
        -target "$TARGET" \
        -framework AppKit -framework SwiftUI -framework Combine \
        Sources/Data.swift Sources/IslandView.swift \
        Tests/TestRunner.swift Tests/TestSupport.swift \
        Tests/MilestoneTests.swift Tests/ThrottleTests.swift Tests/CodexTests.swift
fi

exec "$BUILD"
