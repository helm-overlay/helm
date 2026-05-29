import Foundation

/// Thin seam over `Process` so tests can stub git/CLI invocations without spawning real
/// processes. Shared by `ProjectManager` and the `project` CLI.
public struct ProcessRunner {
    public struct Result: Equatable {
        public let status: Int32
        public let stdout: String
        public let stderr: String
        public init(status: Int32, stdout: String = "", stderr: String = "") {
            self.status = status; self.stdout = stdout; self.stderr = stderr
        }
    }

    public let run: (_ executable: String, _ args: [String], _ cwd: String?) -> Result

    public init(run: @escaping (String, [String], String?) -> Result) {
        self.run = run
    }

    public static let system = ProcessRunner { executable, args, cwd in
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        do { try p.run() } catch {
            return Result(status: -1, stderr: "\(error)")
        }
        p.waitUntilExit()
        let out = String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let err = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return Result(status: p.terminationStatus, stdout: out, stderr: err)
    }
}
