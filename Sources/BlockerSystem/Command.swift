import Foundation

struct CommandResult {
    let status: Int32
    let message: String
}

typealias CommandRunner = (String, [String]) -> CommandResult

func runCommand(_ executable: String, _ arguments: [String]) -> CommandResult {
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = pipe; process.standardError = pipe
    do {
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(status: process.terminationStatus, message: String(data: data, encoding: .utf8) ?? "")
    } catch { return CommandResult(status: -1, message: error.localizedDescription) }
}
