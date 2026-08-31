import Foundation
import XCTest
@testable import Warren

final class WarrenProcessEnvironmentTests: XCTestCase {
    func testCleanEnvironmentDropsTerminalAndTaskContext() {
        let home = URL(fileURLWithPath: "/tmp/warren-home")
        let source: [String: String] = [
            "HOME": home.path,
            "USER": "test",
            "LOGNAME": "test",
            "LANG": "en_US.UTF-8",
            "LC_CTYPE": "UTF-8",
            "SHELL": "/bin/sh",
            "PATH": "/workspace/.mise/shims:/workspace/bin",
            "TERM": "xterm-ghostty",
            "TERM_PROGRAM": "ghostty",
            "MISE_TASK": "install",
            "DIRENV_DIFF": "diff",
            "CODEX_SESSION_ID": "foreign-thread",
            "WARREN_SESSION_ID": "foreign-session",
            "NO_COLOR": "1",
            "HTTP_PROXY": "http://proxy.invalid",
            "CODEX_HOME": "/tmp/warren-home/.codex",
            "WARREN_DATA_DIR": "/tmp/warren-home/.warren",
            "WARREN_CONFIG": "/tmp/warren-home/config.json",
            "WARREN_CODE_SERVER_PATH": "/tmp/warren-home/code-server",
        ]

        let environment = WarrenProcessEnvironment.clean(
            source: source,
            homeDirectory: home
        )

        XCTAssertEqual(environment["HOME"], home.path)
        XCTAssertEqual(environment["USER"], "test")
        XCTAssertEqual(environment["LOGNAME"], "test")
        XCTAssertEqual(environment["LANG"], "en_US.UTF-8")
        XCTAssertEqual(environment["LC_CTYPE"], "UTF-8")
        XCTAssertTrue(
            ["/bin/zsh", "/usr/bin/zsh", "/bin/bash", "/usr/bin/bash", "/bin/sh", "/usr/bin/sh"]
                .contains(environment["SHELL"] ?? "")
        )
        XCTAssertEqual(environment["TERM"], WarrenProcessEnvironment.defaultTerm)
        XCTAssertEqual(environment["COLORTERM"], "truecolor")
        XCTAssertEqual(
            environment["PATH"],
            WarrenProcessEnvironment.stablePath(homeDirectory: home)
        )

        for key in [
            "TERM_PROGRAM", "MISE_TASK", "DIRENV_DIFF", "CODEX_SESSION_ID",
            "WARREN_SESSION_ID", "NO_COLOR", "HTTP_PROXY",
        ] {
            XCTAssertNil(environment[key], "\(key) leaked into clean environment")
        }
        XCTAssertEqual(environment["CODEX_HOME"], "/tmp/warren-home/.codex")
        XCTAssertEqual(environment["WARREN_DATA_DIR"], "/tmp/warren-home/.warren")
        XCTAssertEqual(environment["WARREN_CONFIG"], "/tmp/warren-home/config.json")
        XCTAssertEqual(environment["WARREN_CODE_SERVER_PATH"], "/tmp/warren-home/code-server")
    }

    func testCleanEnvironmentUsesSafeShellFallback() {
        let environment = WarrenProcessEnvironment.clean(
            source: ["HOME": "/tmp/warren-home", "SHELL": "/tmp/not-a-shell"],
            homeDirectory: URL(fileURLWithPath: "/tmp/warren-home")
        )
        XCTAssertNotEqual(environment["SHELL"], "/tmp/not-a-shell")
        XCTAssertTrue(
            ["/bin/zsh", "/usr/bin/zsh", "/bin/bash", "/usr/bin/bash", "/bin/sh", "/usr/bin/sh"]
                .contains(environment["SHELL"] ?? "")
        )
    }
}
