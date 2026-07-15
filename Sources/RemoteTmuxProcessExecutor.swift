import Foundation

/// Launches bounded one-shot tmux helper processes without blocking an actor.
struct RemoteTmuxProcessExecutor: Sendable {
    private let maxCapturedOutputBytes: Int

    init(maxCapturedOutputBytes: Int = 1_048_576) {
        self.maxCapturedOutputBytes = maxCapturedOutputBytes
    }

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil
    ) async throws -> RemoteTmuxCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        let outFD = outPipe.fileHandleForReading.fileDescriptor
        let errFD = errPipe.fileHandleForReading.fileDescriptor
        let maxCapturedOutputBytes = maxCapturedOutputBytes
        let outRead = Task.detached {
            Self.drain(fd: outFD, maxBytes: maxCapturedOutputBytes)
        }
        let errRead = Task.detached {
            Self.drain(fd: errFD, maxBytes: maxCapturedOutputBytes)
        }
        let cancellation = RemoteTmuxProcessCancellation(
            process: process,
            stdout: outPipe.fileHandleForReading,
            stderr: errPipe.fileHandleForReading
        )

        let exitCode: Int32
        do {
            exitCode = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    process.terminationHandler = { proc in
                        continuation.resume(returning: proc.terminationStatus)
                    }
                    do {
                        try process.run()
                    } catch {
                        process.terminationHandler = nil
                        continuation.resume(
                            throwing: RemoteTmuxError.launchFailed(error.localizedDescription)
                        )
                    }
                }
            } onCancel: {
                cancellation.cancel()
            }
            try Task.checkCancellation()
        } catch {
            cancellation.cancel()
            outRead.cancel()
            errRead.cancel()
            _ = await outRead.value
            _ = await errRead.value
            throw error
        }

        let outData = await outRead.value
        let errData = await errRead.value
        return RemoteTmuxCommandResult(
            exitCode: exitCode,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }

    private static func drain(fd: Int32, maxBytes: Int) -> Data {
        var data = Data()
        var remaining = max(0, maxBytes)
        let bufferSize = 65_536
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while true {
            if Task.isCancelled { break }
            let count = buffer.withUnsafeMutableBytes { pointer -> Int in
                read(fd, pointer.baseAddress, bufferSize)
            }
            if count > 0 {
                if remaining > 0 {
                    let kept = min(count, remaining)
                    data.append(contentsOf: buffer[0..<kept])
                    remaining -= kept
                }
            } else if count == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                break
            }
        }
        return data
    }
}
