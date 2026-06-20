import Dispatch
import Darwin
import Foundation

@main
struct MiradorMain {
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard !isSwiftPMTestRunnerInvocation(commandName: CommandLine.arguments.first, arguments: arguments) else { return }

        let options = try parseArguments(arguments)
        let authToken = resolveAuthToken(environment: ProcessInfo.processInfo.environment)

        let frameQueue = MJPEGFrameQueue(capacity: 2)
        let h264Queue = H264FrameQueue(capacity: 2)
        // Shared per-format demand: the server reports MJPEG vs video viewers, the capture
        // callback runs only the encoder(s) someone is watching.
        let consumers = CaptureConsumers()
        let captureService = ScreenCaptureService(frameQueue: frameQueue, h264Queue: h264Queue, consumers: consumers)
        // Demand-driven: capture/encode start on the first viewer and stop when the last
        // disconnects, so the host runs no ScreenCaptureKit/VideoToolbox pipeline while idle.
        let captureCoordinator = CaptureCoordinator(service: captureService)

        let server = try HTTPServer(host: options.host, port: options.port, frameQueue: frameQueue, h264Queue: h264Queue, captureControl: captureCoordinator, consumers: consumers, authToken: authToken)
        server.start()

        let viewerHost = options.host == "0.0.0.0" ? "127.0.0.1" : options.host
        let tokenSuffix = authToken.isEmpty ? "" : "?token=\(authToken)"
        print("mirador 0.1.0-poc listening on http://\(viewerHost):\(options.port)/\(tokenSuffix)")
        print("Press Ctrl-C to stop.")

        let shutdownSignal = await SignalShutdownWaiter.waitForTerminationSignal()
        print("Received \(shutdownSignal.rawValue); shutting down.")
        server.stop()
        await captureService.stop()
    }

    static func parseArguments(_ arguments: [String]) throws -> Options {
        var host = "127.0.0.1"
        var port = 8787
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--host":
                index += 1
                guard index < arguments.count else { throw CLIError.missingValue("--host") }
                host = arguments[index]
            case "--port":
                index += 1
                guard index < arguments.count else { throw CLIError.missingValue("--port") }
                guard let parsedPort = Int(arguments[index]), (1...65535).contains(parsedPort) else {
                    throw CLIError.invalidPort(arguments[index])
                }
                port = parsedPort
            case "--help", "-h":
                printUsage()
                Foundation.exit(0)
            default:
                throw CLIError.unknownArgument(argument)
            }
            index += 1
        }

        return Options(host: host, port: port)
    }

    static func resolveAuthToken(environment: [String: String]) -> String {
        let configured = environment["MIRADOR_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return configured.isEmpty ? UUID().uuidString.replacingOccurrences(of: "-", with: "") : configured
    }

    private static func printUsage() {
        print("""
        Usage: mirador [--host HOST] [--port PORT]

        Options:
          --host HOST   Bind host (default: 127.0.0.1)
          --port PORT   Bind port (default: 8787)
          -h, --help    Show this help
        """)
    }

    static func isSwiftPMTestRunnerInvocation(commandName: String?, arguments: [String]) -> Bool {
        let executableName = commandName.map { URL(fileURLWithPath: $0).lastPathComponent }
        return executableName != "mirador" && arguments.contains("--test-bundle-path")
    }

    struct Options: Equatable {
        let host: String
        let port: Int
    }

    enum CLIError: Error, CustomStringConvertible, Equatable {
        case missingValue(String)
        case invalidPort(String)
        case unknownArgument(String)

        var description: String {
            switch self {
            case .missingValue(let argument):
                return "Missing value for \(argument)"
            case .invalidPort(let value):
                return "Invalid port: \(value)"
            case .unknownArgument(let argument):
                return "Unknown argument: \(argument)"
            }
        }
    }
}

enum ShutdownSignal: String, Sendable {
    case interrupt = "SIGINT"
    case terminate = "SIGTERM"
}

enum SignalShutdownWaiter {
    static func waitForTerminationSignal() async -> ShutdownSignal {
        Darwin.signal(SIGINT, SIG_IGN)
        Darwin.signal(SIGTERM, SIG_IGN)

        return await withCheckedContinuation { continuation in
            let state = OneShotContinuation(continuation)
            let signalQueue = DispatchQueue(label: "mirador.shutdown-signal")

            let interruptSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: signalQueue)
            let terminateSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: signalQueue)

            state.setCleanup {
                interruptSource.cancel()
                terminateSource.cancel()
            }

            interruptSource.setEventHandler {
                state.resume(returning: .interrupt)
            }
            terminateSource.setEventHandler {
                state.resume(returning: .terminate)
            }

            interruptSource.resume()
            terminateSource.resume()
        }
    }
}

final class OneShotContinuation<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    private var cleanup: (() -> Void)?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func setCleanup(_ cleanup: @escaping @Sendable () -> Void) {
        lock.lock()
        if continuation == nil {
            lock.unlock()
            cleanup()
            return
        }
        self.cleanup = cleanup
        lock.unlock()
    }

    @discardableResult
    func resume(returning value: Value) -> Bool {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return false
        }
        self.continuation = nil
        let cleanup = self.cleanup
        self.cleanup = nil
        lock.unlock()

        cleanup?()
        continuation.resume(returning: value)
        return true
    }
}
