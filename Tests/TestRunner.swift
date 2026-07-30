// Test runner — a small, self-contained framework. The shipping toolchain on this
// project doesn't include XCTest (no full Xcode install), and Swift Testing's
// `_TestingInternals` lookup is broken on the bundled toolchain. Rolling a 60-line
// `expect` helper set is cheaper than fighting the toolchain, and keeps the tests
// runnable with nothing but `swiftc`.
//
// Each test file declares a struct with a `static func run() async` that calls its
// individual test methods. The runner invokes them in order, prints a summary, and
// returns a non-zero exit code on any failure. `expect*` are thin wrappers around
// XCTest-style asserts — they record file/line and accumulate pass/fail counts.
//
// All tests are `@MainActor` because the store they exercise is `@MainActor`.
// A Swift concurrency task hops to the main actor implicitly when calling them.

import Foundation

@MainActor
final class TestRunner {
    static let shared = TestRunner()
    private(set) var passes = 0
    private(set) var failures: [String] = []

    func expect(_ condition: @autoclosure () -> Bool, _ message: String = "",
                file: StaticString = #file, line: UInt = #line) {
        if condition() {
            passes += 1
        } else {
            failures.append("\(file):\(line) — \(message)")
        }
    }

    func expectEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = "",
                                   file: StaticString = #file, line: UInt = #line) {
        if a == b {
            passes += 1
        } else {
            failures.append("\(file):\(line) — expected \(b), got \(a) — \(message)")
        }
    }

    func expectNotEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = "",
                                      file: StaticString = #file, line: UInt = #line) {
        if a != b {
            passes += 1
        } else {
            failures.append("\(file):\(line) — expected ≠ \(b), got \(a) — \(message)")
        }
    }

    func expectNil<T>(_ a: T?, _ message: String = "",
                      file: StaticString = #file, line: UInt = #line) {
        if a == nil {
            passes += 1
        } else {
            failures.append("\(file):\(line) — expected nil, got \(String(describing: a)) — \(message)")
        }
    }

    func expectNotNil<T>(_ a: T?, _ message: String = "",
                         file: StaticString = #file, line: UInt = #line) {
        if a != nil {
            passes += 1
        } else {
            failures.append("\(file):\(line) — expected non-nil — \(message)")
        }
    }

    // Log a failure from a `guard … else` branch where there's no value to compare.
    // Keeps the call site short without forcing generic-parameter inference.
    func fail(_ message: String = "",
              file: StaticString = #file, line: UInt = #line) {
        failures.append("\(file):\(line) — \(message)")
    }

    func expectApprox(_ a: Double, _ b: Double, tolerance: Double = 0.5,
                      _ message: String = "",
                      file: StaticString = #file, line: UInt = #line) {
        if abs(a - b) <= tolerance {
            passes += 1
        } else {
            failures.append("\(file):\(line) — expected ≈\(b) (within \(tolerance)), got \(a) — \(message)")
        }
    }

    func report() -> Int32 {
        print("---")
        print("\(passes) assertions passed, \(failures.count) failed")
        for f in failures {
            print("FAIL: \(f)")
        }
        return failures.isEmpty ? 0 : 1
    }
}

// Free-function wrappers so test bodies read naturally.
@MainActor
func expect(_ condition: @autoclosure () -> Bool, _ message: String = "",
            file: StaticString = #file, line: UInt = #line) {
    TestRunner.shared.expect(condition(), message, file: file, line: line)
}
@MainActor
func expectEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = "",
                               file: StaticString = #file, line: UInt = #line) {
    TestRunner.shared.expectEqual(a, b, message, file: file, line: line)
}
@MainActor
func expectNotEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = "",
                                  file: StaticString = #file, line: UInt = #line) {
    TestRunner.shared.expectNotEqual(a, b, message, file: file, line: line)
}
@MainActor
func expectNil<T>(_ a: T?, _ message: String = "",
                  file: StaticString = #file, line: UInt = #line) {
    TestRunner.shared.expectNil(a, message, file: file, line: line)
}
@MainActor
func expectNotNil<T>(_ a: T?, _ message: String = "",
                     file: StaticString = #file, line: UInt = #line) {
    TestRunner.shared.expectNotNil(a, message, file: file, line: line)
}
@MainActor
func fail(_ message: String = "",
          file: StaticString = #file, line: UInt = #line) {
    TestRunner.shared.fail(message, file: file, line: line)
}
@MainActor
func expectApprox(_ a: Double, _ b: Double, tolerance: Double = 0.5,
                  _ message: String = "",
                  file: StaticString = #file, line: UInt = #line) {
    TestRunner.shared.expectApprox(a, b, tolerance: tolerance, message,
                                    file: file, line: line)
}

// Entry point for the test executable.
@main
struct TestMain {
    static func main() async {
        let runner = TestRunner.shared
        await MilestoneTests.run()
        await ThrottleTests.run()
        await CodexTests.run()
        let code = runner.report()
        exit(code)
    }
}
