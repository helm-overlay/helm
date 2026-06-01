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
        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                group.leave()
            } else {
                outData.append(data)
            }
        }
        group.enter()
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                group.leave()
            } else {
                errData.append(data)
            }
        }
        do { try p.run() } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            group.leave()
            group.leave()
            return Result(status: -1, stderr: "\(error)")
        }
        p.waitUntilExit()
        group.wait()
        let out = String(decoding: outData, as: UTF8.self)
        let err = String(decoding: errData, as: UTF8.self)
        return Result(status: p.terminationStatus, stdout: out, stderr: err)
    }
}
