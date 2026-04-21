import XCTest
import Foundation
import Darwin

final class WindowOwnershipUITests: XCTestCase {
    private var socketPath = ""
    private var launchTag = ""

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        socketPath = "/tmp/cmux-ui-test-window-ownership-\(UUID().uuidString).sock"
        launchTag = "ui-tests-window-ownership-\(UUID().uuidString.prefix(8))"
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: socketPath)
        super.tearDown()
    }

    func testSecondWindowCreatedViaCmdShiftNHasDistinctWindowIdInIdentify() throws {
        let snapshot = try launchAndCaptureWindowOwnership()

        XCTAssertNotEqual(snapshot.window1Id, snapshot.window2Id)
    }

    func testEachWindowHasIndependentOpenProjectIds() throws {
        let snapshot = try launchAndCaptureWindowOwnership()

        XCTAssertEqual(snapshot.window1OpenProjectIds.count, 1)
        XCTAssertEqual(snapshot.window2OpenProjectIds.count, 1)
        XCTAssertTrue(
            Set(snapshot.window1OpenProjectIds).isDisjoint(with: Set(snapshot.window2OpenProjectIds)),
            "Expected each window to keep its own default project container"
        )
    }

    private struct WindowOwnershipSnapshot {
        let window1Id: String
        let window2Id: String
        let window1OpenProjectIds: [String]
        let window2OpenProjectIds: [String]
    }

    private func launchAndCaptureWindowOwnership() throws -> WindowOwnershipSnapshot {
        let app = XCUIApplication()
        app.launchArguments += ["-socketControlMode", "allowAll"]
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_SOCKET_MODE"] = "allowAll"
        app.launchEnvironment["CMUX_SOCKET_ENABLE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_SOCKET_SANITY"] = "1"
        app.launchEnvironment["CMUX_TAG"] = launchTag
        app.launch()
        defer { app.terminate() }

        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: 12.0),
            "Expected app to launch for window ownership test. state=\(app.state.rawValue)"
        )
        XCTAssertTrue(waitForSocketPong(timeout: 12.0), "Expected control socket to respond at \(socketPath)")
        XCTAssertTrue(waitForWindowCount(app: app, atLeast: 1, timeout: 6.0))

        app.activate()
        app.typeKey("n", modifierFlags: [.command, .shift])

        XCTAssertTrue(waitForWindowCount(app: app, atLeast: 2, timeout: 8.0), "Expected Cmd+Shift+N to create a second window")

        let window1Payload = try XCTUnwrap(identifyPayload(forWindow: "1"))
        let window2Payload = try XCTUnwrap(identifyPayload(forWindow: "2"))
        let focused1 = try XCTUnwrap(window1Payload["focused"] as? [String: Any])
        let focused2 = try XCTUnwrap(window2Payload["focused"] as? [String: Any])
        let window1Id = try XCTUnwrap(focused1["window_id"] as? String)
        let window2Id = try XCTUnwrap(focused2["window_id"] as? String)
        let window1Projects = stringArray(focused1["open_project_ids"])
        let window2Projects = stringArray(focused2["open_project_ids"])

        XCTAssertFalse(window1Projects.isEmpty, "Expected window 1 to report its default project")
        XCTAssertFalse(window2Projects.isEmpty, "Expected window 2 to report its default project")

        return WindowOwnershipSnapshot(
            window1Id: window1Id,
            window2Id: window2Id,
            window1OpenProjectIds: window1Projects,
            window2OpenProjectIds: window2Projects
        )
    }

    private func identifyPayload(forWindow windowHandle: String) -> [String: Any]? {
        let result = runCmuxCommand(
            socketPath: socketPath,
            arguments: ["identify", "--window", windowHandle, "--json"],
            cliStrategy: .bundledOnly
        )
        guard result.terminationStatus == 0 else {
            XCTFail("cmux identify failed for window \(windowHandle): stdout=\(result.stdout) stderr=\(result.stderr)")
            return nil
        }
        guard let data = result.stdout.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("Expected JSON output from cmux identify for window \(windowHandle). stdout=\(result.stdout)")
            return nil
        }
        return payload
    }

    private func stringArray(_ value: Any?) -> [String] {
        (value as? [Any])?.compactMap { $0 as? String } ?? []
    }

    private func ensureForegroundAfterLaunch(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        if app.wait(for: .runningForeground, timeout: timeout) {
            return true
        }
        if app.state == .runningBackground {
            app.activate()
            return app.wait(for: .runningForeground, timeout: 6.0)
        }
        return false
    }

    private func waitForWindowCount(app: XCUIApplication, atLeast count: Int, timeout: TimeInterval) -> Bool {
        waitForCondition(timeout: timeout) {
            app.windows.count >= count
        }
    }

    private func waitForSocketPong(timeout: TimeInterval) -> Bool {
        waitForCondition(timeout: timeout) {
            self.socketCommand("ping") == "PONG"
        }
    }

    private func waitForCondition(timeout: TimeInterval, condition: @escaping () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }

    private func socketCommand(_ cmd: String, responseTimeout: TimeInterval = 2.0) -> String? {
        ControlSocketClient(path: socketPath, responseTimeout: responseTimeout).sendLine(cmd)
    }

    private func runCmuxCommand(
        socketPath: String,
        arguments: [String],
        responseTimeoutSeconds: Double = 3.0,
        cliStrategy: CmuxCLIStrategy = .any
    ) -> (terminationStatus: Int32, stdout: String, stderr: String) {
        var args = ["--socket", socketPath]
        args.append(contentsOf: arguments)
        var environment = ProcessInfo.processInfo.environment
        environment["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"] = String(responseTimeoutSeconds)

        let cliPaths = resolveCmuxCLIPaths(strategy: cliStrategy)
        if cliPaths.isEmpty, cliStrategy == .bundledOnly {
            return (
                terminationStatus: -1,
                stdout: "",
                stderr: "Failed to locate bundled cmux CLI"
            )
        }

        for cliPath in cliPaths {
            let result = executeCmuxCommand(
                executablePath: cliPath,
                arguments: args,
                environment: environment
            )
            if result.terminationStatus == 0 {
                return result
            }
            if !result.stderr.localizedCaseInsensitiveContains("operation not permitted") {
                return result
            }
        }

        let fallbackArgs = ["cmux"] + args
        return executeCmuxCommand(
            executablePath: "/usr/bin/env",
            arguments: fallbackArgs,
            environment: environment
        )
    }

    private enum CmuxCLIStrategy: Equatable {
        case any
        case bundledOnly
    }

    private func resolveCmuxCLIPaths(strategy: CmuxCLIStrategy) -> [String] {
        let fileManager = FileManager.default
        let env = ProcessInfo.processInfo.environment
        var candidates: [String] = []
        var productDirectories: [String] = []

        if strategy == .any {
            for key in ["CMUX_UI_TEST_CLI_PATH", "CMUXTERM_CLI"] {
                if let value = env[key], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    candidates.append(value)
                }
            }
        }

        if let builtProductsDir = env["BUILT_PRODUCTS_DIR"], !builtProductsDir.isEmpty {
            productDirectories.append(builtProductsDir)
        }

        if let hostPath = env["TEST_HOST"], !hostPath.isEmpty {
            let hostURL = URL(fileURLWithPath: hostPath)
            let productsDir = hostURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .path
            productDirectories.append(productsDir)
        }

        productDirectories.append(contentsOf: inferredBuildProductsDirectories())
        for productsDir in uniquePaths(productDirectories) {
            appendCLIPathCandidates(fromProductsDirectory: productsDir, strategy: strategy, to: &candidates)
        }

        var resolvedPaths: [String] = []
        for path in uniquePaths(candidates) {
            guard fileManager.isExecutableFile(atPath: path) else { continue }
            resolvedPaths.append(URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
        }
        return uniquePaths(resolvedPaths)
    }

    private func inferredBuildProductsDirectories() -> [String] {
        let bundleURLs = [
            Bundle.main.bundleURL,
            Bundle(for: Self.self).bundleURL,
        ]

        return bundleURLs.compactMap { bundleURL in
            let standardizedPath = bundleURL.standardizedFileURL.path
            let components = standardizedPath.split(separator: "/")
            guard let productsIndex = components.firstIndex(of: "Products"),
                  productsIndex + 1 < components.count else {
                return nil
            }
            let prefixComponents = components.prefix(productsIndex + 2)
            return "/" + prefixComponents.joined(separator: "/")
        }
    }

    private func appendCLIPathCandidates(
        fromProductsDirectory productsDir: String,
        strategy: CmuxCLIStrategy,
        to candidates: inout [String]
    ) {
        candidates.append("\(productsDir)/cmux DEV.app/Contents/Resources/bin/cmux")
        candidates.append("\(productsDir)/cmux.app/Contents/Resources/bin/cmux")
        if strategy == .any {
            candidates.append("\(productsDir)/cmux")
        }

        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: productsDir) else {
            return
        }

        for entry in entries.sorted() where entry.hasSuffix(".app") {
            let cliPath = URL(fileURLWithPath: productsDir)
                .appendingPathComponent(entry)
                .appendingPathComponent("Contents/Resources/bin/cmux")
                .path
            candidates.append(cliPath)
        }
        if strategy == .any {
            for entry in entries.sorted() where entry == "cmux" {
                let cliPath = URL(fileURLWithPath: productsDir)
                    .appendingPathComponent(entry)
                    .path
                candidates.append(cliPath)
            }
        }
    }

    private func executeCmuxCommand(
        executablePath: String,
        arguments: [String],
        environment: [String: String]
    ) -> (terminationStatus: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (
                terminationStatus: -1,
                stdout: "",
                stderr: "Failed to run cmux command: \(error.localizedDescription) (cliPath=\(executablePath))"
            )
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rawStderr = String(data: stderrData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = rawStderr.isEmpty ? "" : "\(rawStderr) (cliPath=\(executablePath))"
        return (process.terminationStatus, stdout, stderr)
    }

    private func uniquePaths(_ paths: [String]) -> [String] {
        var unique: [String] = []
        var seen = Set<String>()
        for path in paths where seen.insert(path).inserted {
            unique.append(path)
        }
        return unique
    }

    private final class ControlSocketClient {
        private let path: String
        private let responseTimeout: TimeInterval

        init(path: String, responseTimeout: TimeInterval = 2.0) {
            self.path = path
            self.responseTimeout = responseTimeout
        }

        func sendLine(_ line: String) -> String? {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            defer { close(fd) }

            var socketTimeout = timeval(
                tv_sec: Int(responseTimeout.rounded(.down)),
                tv_usec: Int32(((responseTimeout - floor(responseTimeout)) * 1_000_000).rounded())
            )

#if os(macOS)
            var noSigPipe: Int32 = 1
            _ = withUnsafePointer(to: &noSigPipe) { ptr in
                setsockopt(
                    fd,
                    SOL_SOCKET,
                    SO_NOSIGPIPE,
                    ptr,
                    socklen_t(MemoryLayout<Int32>.size)
                )
            }
#endif
            _ = withUnsafePointer(to: &socketTimeout) { ptr in
                setsockopt(
                    fd,
                    SOL_SOCKET,
                    SO_RCVTIMEO,
                    ptr,
                    socklen_t(MemoryLayout<timeval>.size)
                )
            }
            _ = withUnsafePointer(to: &socketTimeout) { ptr in
                setsockopt(
                    fd,
                    SOL_SOCKET,
                    SO_SNDTIMEO,
                    ptr,
                    socklen_t(MemoryLayout<timeval>.size)
                )
            }

            var addr = sockaddr_un()
            memset(&addr, 0, MemoryLayout<sockaddr_un>.size)
            addr.sun_family = sa_family_t(AF_UNIX)

            let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
            let bytes = Array(path.utf8CString)
            guard bytes.count <= maxLen else { return nil }
            withUnsafeMutablePointer(to: &addr.sun_path) { pointer in
                let raw = UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self)
                memset(raw, 0, maxLen)
                for index in 0..<bytes.count {
                    raw[index] = bytes[index]
                }
            }

            let pathOffset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) ?? 0
            let addrLen = socklen_t(pathOffset + bytes.count)
#if os(macOS)
            addr.sun_len = UInt8(min(Int(addrLen), 255))
#endif

            let connected = withUnsafePointer(to: &addr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    connect(fd, socketAddress, addrLen)
                }
            }
            guard connected == 0 else { return nil }

            let payload = line + "\n"
            let wrote: Bool = payload.withCString { cString in
                var remaining = strlen(cString)
                var pointer = UnsafeRawPointer(cString)
                while remaining > 0 {
                    let written = write(fd, pointer, remaining)
                    if written <= 0 { return false }
                    remaining -= written
                    pointer = pointer.advanced(by: written)
                }
                return true
            }
            guard wrote else { return nil }

            var buffer = [UInt8](repeating: 0, count: 4096)
            var response = ""
            while true {
                let readCount = read(fd, &buffer, buffer.count)
                if readCount < 0 {
                    let code = errno
                    if code == EAGAIN || code == EWOULDBLOCK {
                        break
                    }
                    return nil
                }
                if readCount <= 0 { break }
                if let chunk = String(bytes: buffer[0..<readCount], encoding: .utf8) {
                    response.append(chunk)
                    if let newlineIndex = response.firstIndex(of: "\n") {
                        return String(response[..<newlineIndex])
                    }
                }
            }
            return response.isEmpty ? nil : response.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
