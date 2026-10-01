//
//  PhoneAgentRPCClient.swift
//  PhoneAgent
//
//  Created by Rounak Jain on 5/31/25.
//

import Foundation
import Network

public actor PhoneAgentRPCClient {
    private enum Error: Swift.Error, LocalizedError {
        case invalidRequest
        case connectTimeout
        case readTimeout
        case connectionClosed
        case responseTooLarge(maximumBytes: Int)
        case invalidJSONResponse

        var errorDescription: String? {
            switch self {
            case .invalidRequest:
                "Invalid RPC request"
            case .connectTimeout:
                "RPC connect timed out"
            case .readTimeout:
                "RPC read timed out"
            case .connectionClosed:
                "RPC connection closed"
            case .responseTooLarge(let maximumBytes):
                "RPC response exceeded max size (\(maximumBytes) bytes)"
            case .invalidJSONResponse:
                "Invalid JSON response"
            }
        }
    }

    private let host: NWEndpoint.Host = .ipv4(IPv4Address.loopback)
    private static let defaultPort: NWEndpoint.Port = NWEndpoint.Port(rawValue: 45678)!
    private let port: NWEndpoint.Port = PhoneAgentRPCClient.defaultPort
    private let queue = DispatchQueue(label: "com.phoneagent.rpc.client")
    private var nextRequestID: Int = 1

    private let connectTimeoutNanoseconds: UInt64 = 5_000_000_000
    private let readTimeoutNanoseconds: UInt64 = 15_000_000_000
    private let maximumResponseBytes: Int = 10 * 1024 * 1024

    public init() {}

    // MARK: - High-level calls used by the app UI

    public func setOpenAIAPIKey(_ apiKey: String) async {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = await callIgnoringErrors(method: "set_api_key", parameters: ["api_key": trimmed])
    }

    public func submitPrompt(_ prompt: String) async {
        _ = await callIgnoringErrors(method: "submit_prompt", parameters: ["prompt": prompt])
    }

    // MARK: - Transport

    private static func withTimeout<T>(
        queue: DispatchQueue,
        timeoutNanoseconds: UInt64,
        timeoutError: Swift.Error,
        onTimeout: (() -> Void)? = nil,
        operation: (@escaping (Result<T, Swift.Error>) -> Void) -> Void
    ) async throws -> T {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Swift.Error>) in
            var done = false

            func finish(_ result: Result<T, Swift.Error>) {
                guard !done else { return }
                done = true
                timeoutItem.cancel()
                cont.resume(with: result)
            }

            let timeoutItem = DispatchWorkItem {
                guard !done else { return }
                done = true
                onTimeout?()
                cont.resume(throwing: timeoutError)
            }

            queue.asyncAfter(
                deadline: .now() + .nanoseconds(Int(timeoutNanoseconds)),
                execute: timeoutItem
            )

            operation(finish)
        }
    }

    private func callIgnoringErrors(method: String, parameters: [String: Any]) async -> [String: Any]? {
        do {
            let response = try await call(method: method, parameters: parameters)
            if let error = response["error"] {
                print("RPC error (\(method)): \(error)")
            }
            return response
        } catch {
            print("RPC call failed (\(method)): \(error.localizedDescription)")
            return nil
        }
    }

    private func call(method: String, parameters: [String: Any]) async throws -> [String: Any] {
        let requestID = nextRequestID
        nextRequestID += 1

        let request: [String: Any] = [
            "id": requestID,
            "method": method,
            "params": parameters
        ]

        guard JSONSerialization.isValidJSONObject(request) else {
            throw Error.invalidRequest
        }

        var payload = try JSONSerialization.data(withJSONObject: request, options: [])
        payload.append(0x0A)

        let connection = NWConnection(host: host, port: port, using: .tcp)
        defer { connection.cancel() }

        try await connect(connection)
        try await send(connection, data: payload)
        let line = try await receiveLine(connection)

        guard let responseObject = try JSONSerialization.jsonObject(with: line, options: []) as? [String: Any] else {
            throw Error.invalidJSONResponse
        }
        return responseObject
    }

    private func connect(_ connection: NWConnection) async throws {
        let queue = self.queue
        let connectTimeoutNanoseconds = self.connectTimeoutNanoseconds

        try await PhoneAgentRPCClient.withTimeout(
            queue: queue,
            timeoutNanoseconds: connectTimeoutNanoseconds,
            timeoutError: Error.connectTimeout,
            onTimeout: { connection.cancel() }
        ) { finish in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(.success(()))
                case .failed(let error):
                    finish(.failure(error))
                case .cancelled:
                    finish(.failure(Error.connectionClosed))
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    private func send(_ connection: NWConnection, data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Swift.Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            })
        }
    }

    private func receiveLine(_ connection: NWConnection) async throws -> Data {
        let queue = self.queue
        let readTimeoutNanoseconds = self.readTimeoutNanoseconds
        let maximumResponseBytes = self.maximumResponseBytes

        return try await PhoneAgentRPCClient.withTimeout(
            queue: queue,
            timeoutNanoseconds: readTimeoutNanoseconds,
            timeoutError: Error.readTimeout,
            onTimeout: { connection.cancel() }
        ) { finish in
            var buffer = Data()

            func receiveNext() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                    if let error {
                        finish(.failure(error))
                        return
                    }

                    if let data, !data.isEmpty {
                        if let nl = data.firstIndex(of: 0x0A) {
                            buffer.append(data[..<nl])
                            finish(.success(buffer))
                            return
                        }

                        buffer.append(data)
                        if buffer.count > maximumResponseBytes {
                            finish(.failure(Error.responseTooLarge(maximumBytes: maximumResponseBytes)))
                            return
                        }
                    }

                    if isComplete {
                        finish(.failure(Error.connectionClosed))
                        return
                    }

                    receiveNext()
                }
            }

            receiveNext()
        }
    }
}
