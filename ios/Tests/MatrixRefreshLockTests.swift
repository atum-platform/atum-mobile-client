import XCTest
@testable import AtumNativeAPI

final class MatrixRefreshLockTests: XCTestCase {
    func testIndependentDescriptorsAreExclusiveAndReleaseOnClose() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("refresh.lock")
        var first: MatrixRefreshLease? = try MatrixRefreshLease.acquire(at: path)
        XCTAssertNotNil(first)
        XCTAssertThrowsError(try MatrixRefreshLease.acquire(at: path)) {
            XCTAssertEqual($0 as? MatrixRefreshFailure, .busy)
        }
        first = nil
        XCTAssertNoThrow(try MatrixRefreshLease.acquire(at: path))
    }

    #if os(macOS)
    func testOtherProcessHoldsLockAndKernelReleasesAfterProcessDeath() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("refresh.lock")
        let child = Process(), output = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-c", "import fcntl,os,sys,time; f=open(sys.argv[1],'a'); fcntl.flock(f,fcntl.LOCK_EX); os.write(1,b'1'); time.sleep(30)", path.path]
        child.standardOutput = output
        try child.run()
        defer { if child.isRunning { child.terminate(); child.waitUntilExit() } }
        XCTAssertEqual(output.fileHandleForReading.readData(ofLength: 1), Data("1".utf8))
        XCTAssertThrowsError(try MatrixRefreshLease.acquire(at: path)) {
            XCTAssertEqual($0 as? MatrixRefreshFailure, .busy)
        }
        child.terminate(); child.waitUntilExit()
        XCTAssertNoThrow(try MatrixRefreshLease.acquire(at: path))
    }
    #endif

    @MainActor func testNotificationDeadlineCancelsRefreshWork() async throws {
        var cancelled = false
        do {
            _ = try await MatrixNotificationSession.bounded(seconds: 0.01) {
                do { try await Task.sleep(for: .seconds(30)) }
                catch { cancelled = true; throw error }
                return 1
            }
            XCTFail("Deadline must cancel the exchange")
        } catch { XCTAssertEqual(error as? MatrixRefreshFailure, .timedOut) }
        XCTAssertTrue(cancelled)
    }
}
