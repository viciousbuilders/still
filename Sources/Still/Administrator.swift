import Foundation

enum Administrator {
    static func run(helper: URL, arguments: [String]) async throws {
        let command = ([helper.path] + arguments).map(shellQuote).joined(separator: " ")
        let script = "do shell script \"\(appleScriptEscape(command))\" with administrator privileges with prompt \"Still needs permission to update your website block.\""
        try await Task.detached(priority: .userInitiated) {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            process.standardOutput = output; process.standardError = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let message = String(data: data, encoding: .utf8) ?? "Administrator permission was not granted."
                if message.contains("(-128)") { throw AdminError.cancelled }
                throw AdminError.failed(message.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }.value
    }

    private static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private static func appleScriptEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

enum AdminError: LocalizedError {
    case cancelled, failed(String)
    var errorDescription: String? {
        switch self {
        case .cancelled: return "Permission was cancelled. Your existing block is unchanged."
        case .failed(let message): return message
        }
    }
}
