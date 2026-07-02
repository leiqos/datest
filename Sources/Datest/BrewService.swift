import Foundation

/// Runs Homebrew operations. Security posture:
/// - `brew` is executed directly via Process with an argument array — never
///   through a shell, so cask tokens can't inject commands.
/// - Tokens are validated against Homebrew's token charset before use.
/// - NONINTERACTIVE=1: anything that would prompt (e.g. sudo for pkg
///   installers) fails with a visible error instead of hanging or escalating.
/// - This app never downloads or executes app binaries itself; Homebrew
///   verifies each download against the SHA-256 checksum in the cask.
enum BrewService {
    static let brewPath: String? = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    static var available: Bool { brewPath != nil }

    static func isValidToken(_ token: String) -> Bool {
        !token.isEmpty && token.count < 100
            && token.range(of: #"^[a-z0-9@+\-\.]+$"#, options: .regularExpression) != nil
    }

    /// Cask tokens Homebrew already manages (directories in the Caskroom).
    static func managedTokens() -> Set<String> {
        guard let brewPath else { return [] }
        let caskroom = URL(fileURLWithPath: brewPath)
            .deletingLastPathComponent()  // bin
            .deletingLastPathComponent()  // prefix
            .appendingPathComponent("Caskroom")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: caskroom, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])
        else { return [] }
        return Set(entries.filter { $0.hasDirectoryPath }.map { $0.lastPathComponent })
    }

    enum Operation: Equatable {
        case install    // brew install --cask <token>
        case upgrade    // brew upgrade --cask <token>
        case takeOver   // brew install --cask --force <token>: replaces an
                        // existing non-brew copy with brew's verified download,
                        // updating it and making it brew-managed from then on
        case adopt      // brew install --cask --adopt <token>: registers an
                        // identical existing copy without reinstalling

        var arguments: [String] {
            switch self {
            case .install:  return ["install", "--cask"]
            case .upgrade:  return ["upgrade", "--cask"]
            case .takeOver: return ["install", "--cask", "--force"]
            case .adopt:    return ["install", "--cask", "--adopt"]
            }
        }

        var label: String {
            switch self {
            case .install: return "Installing"
            case .upgrade: return "Updating"
            case .takeOver: return "Updating via Homebrew"
            case .adopt: return "Adopting into Homebrew"
            }
        }
    }

    struct BrewError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Runs a brew operation; throws BrewError with brew's output on failure.
    static func run(_ operation: Operation, token: String) async throws {
        guard let brewPath else { throw BrewError(message: "Homebrew is not installed.") }
        guard isValidToken(token) else { throw BrewError(message: "Invalid cask token: \(token)") }

        let result: (status: Int32, output: String) = try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: brewPath)
            process.arguments = operation.arguments + [token]
            var env = ProcessInfo.processInfo.environment
            env["NONINTERACTIVE"] = "1"
            env["HOMEBREW_NO_ANALYTICS"] = "1"
            env["HOMEBREW_NO_COLOR"] = "1"
            // GUI apps get a minimal PATH from launchd; brew's dir must be on it.
            let brewBin = (brewPath as NSString).deletingLastPathComponent
            env["PATH"] = "\(brewBin):" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
            // Casks that need admin rights: sudo shows a native password dialog
            // instead of failing. The password flows dialog → sudo, never here.
            if let askpass = askpassPath {
                env["SUDO_ASKPASS"] = askpass
            }
            process.environment = env

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(data: data, encoding: .utf8) ?? ""
            return (process.terminationStatus, output)
        }.value

        if result.status != 0 {
            // Surface the tail of brew's output — that's where the error is.
            let cleaned = result.output.replacingOccurrences(
                of: "\u{1B}\\[[0-9;]*m|==> ", with: "", options: .regularExpression)
            let lines = cleaned
                .split(separator: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            var message = lines.suffix(6).joined(separator: "\n")
            if message.isEmpty { message = "brew exited with status \(result.status)" }
            if cleaned.contains("password is required") || cleaned.contains("a terminal is required") {
                message += "\n\nThis app needs administrator rights to install. "
                    + (askpassPath != nil
                        ? "Try again and approve the password prompt."
                        : "Run this in Terminal instead: brew \(operation.arguments.joined(separator: " ")) \(token)")
            } else if cleaned.contains("Operation not permitted") || cleaned.contains("Permission denied") {
                message += "\n\nHomebrew can't modify this app — it was installed "
                    + "with system privileges. Update it with its own built-in "
                    + "updater or the vendor's installer instead."
            }
            throw BrewError(message: message)
        }
    }

    /// Bundled SUDO_ASKPASS helper (nil when running as a bare CLI binary).
    static let askpassPath: String? = {
        guard let path = Bundle.main.path(forResource: "askpass", ofType: "sh"),
              FileManager.default.isExecutableFile(atPath: path)
        else { return nil }
        return path
    }()
}
