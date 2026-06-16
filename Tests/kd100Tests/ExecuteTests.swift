import XCTest
@testable import kd100

/// Exercises the real command pipeline (`$SHELL -ilc` spawn → exit status + stderr
/// capture). These spawn an actual shell, so they're local-only (CI builds but does
/// not run the test suite). Commands used are POSIX, so they pass under zsh or bash.
final class ExecuteTests: XCTestCase {
    private func makeMapping() -> Mapping {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kd100-exec-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return Mapping(path: dir.appendingPathComponent("mapping.json").path)
    }

    func testSuccessfulCommandReportsZero() {
        let m = makeMapping()
        let done = expectation(description: "command finished")
        m.test(name: "7", command: "exit 0") { code, tail in
            XCTAssertEqual(code, 0)
            XCTAssertEqual(tail, "")
            done.fulfill()
        }
        wait(for: [done], timeout: 20)
    }

    func testFailingCommandReportsExitCode() {
        let m = makeMapping()
        let done = expectation(description: "command finished")
        m.test(name: "7", command: "exit 7") { code, _ in
            XCTAssertEqual(code, 7)
            done.fulfill()
        }
        wait(for: [done], timeout: 20)
    }

    func testStderrIsCapturedAndCleaned() {
        let m = makeMapping()
        let done = expectation(description: "command finished")
        m.test(name: "minus", command: "echo boom 1>&2; exit 3") { code, tail in
            XCTAssertEqual(code, 3)
            XCTAssertTrue(tail.contains("boom"), "stderr tail should contain the error, got: \(tail)")
            XCTAssertFalse(tail.contains("can't change option:"), "zsh artifacts should be filtered")
            done.fulfill()
        }
        wait(for: [done], timeout: 20)
    }

    func testInheritsLoginPathForCommonTools() {
        // The whole point of `-ilc`: resolve a tool that lives outside the old
        // hardcoded PATH. `command -v` is a shell builtin, so this is hermetic.
        let m = makeMapping()
        let done = expectation(description: "command finished")
        m.test(name: "1", command: "command -v env >/dev/null") { code, _ in
            XCTAssertEqual(code, 0)
            done.fulfill()
        }
        wait(for: [done], timeout: 20)
    }
}
