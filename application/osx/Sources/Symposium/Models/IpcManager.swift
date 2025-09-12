import Combine
import CoreGraphics
import Foundation

// MARK: - IPC Message Types

/// Sender information for message routing
// ANCHOR: message_sender
struct MessageSender: Codable {
    let workingDirectory: String
    let taskspaceUuid: String?
    let shellPid: Int?
    
    private enum CodingKeys: String, CodingKey {
        case workingDirectory = "workingDirectory"
        case taskspaceUuid = "taskspaceUuid"
        case shellPid = "shellPid"
    }
}
// ANCHOR_END: message_sender

/// Base IPC message structure for communication with VSCode extension via daemon
// ANCHOR: ipc_message
struct IPCMessage: Codable {
    let type: String
    let payload: JsonBlob
    let id: String
    let sender: MessageSender
    
    private enum CodingKeys: String, CodingKey {
        case type, payload, id, sender
    }
}
// ANCHOR_END: ipc_message

/// Request from VSCode extension to determine if agent should launch for a taskspace
struct GetTaskspaceStatePayload: Codable {
    let taskspaceUuid: String
}

/// Response to get_taskspace_state with agent launch decision
struct TaskspaceStateResponse: Codable {
    let agentCommand: [String]
    let shouldLaunch: Bool
}

/// Request from MCP tool to create a new taskspace
struct SpawnTaskspacePayload: Codable {
    let projectPath: String
    let taskspaceUuid: String  // UUID of parent taskspace requesting the spawn
    let name: String
    let taskDescription: String
    let initialPrompt: String

    private enum CodingKeys: String, CodingKey {
        case projectPath = "project_path"
        case taskspaceUuid = "taskspace_uuid"
        case name
        case taskDescription = "task_description"
        case initialPrompt = "initial_prompt"
    }
}

/// Response to spawn_taskspace with new taskspace UUID
struct SpawnTaskspaceResponse: Codable {
    let newTaskspaceUuid: String
}

/// Request to update taskspace name and description
struct UpdateTaskspacePayload: Codable {
    let taskspaceUuid: String
    let name: String
    let description: String
    let projectPath: String

    private enum CodingKeys: String, CodingKey {
        case taskspaceUuid = "taskspace_uuid"
        case name, description
        case projectPath = "project_path"
    }
}

/// Progress update from MCP tool for taskspace activity logs
struct LogProgressPayload: Codable {
    let projectPath: String
    let taskspaceUuid: String
    let message: String
    let category: String

    private enum CodingKeys: String, CodingKey {
        case projectPath = "project_path"
        case taskspaceUuid = "taskspace_uuid"
        case message, category
    }
}

/// Request from MCP tool for user attention (highlights taskspace, dock badge)
struct SignalUserPayload: Codable {
    let projectPath: String
    let taskspaceUuid: String
    let message: String

    private enum CodingKeys: String, CodingKey {
        case projectPath = "project_path"
        case taskspaceUuid = "taskspace_uuid"
        case message
    }
}

struct TaskspaceRollCallPayload: Codable {
    let taskspaceUuid: String

    private enum CodingKeys: String, CodingKey {
        case taskspaceUuid = "taskspace_uuid"
    }
}

struct RegisterTaskspaceWindowPayload: Codable {
    let windowTitle: String
    let taskspaceUuid: String

    private enum CodingKeys: String, CodingKey {
        case windowTitle = "window_title"
        case taskspaceUuid = "taskspace_uuid"
    }
}

// MARK: - IPC Message Handling Protocol

/// Result of attempting to handle an IPC message
enum MessageHandlingResult<T: Codable> {
    case handled(T?)
    case notForMe
}

/// Protocol for objects that can handle IPC messages (typically one per active project)
protocol IpcMessageDelegate: AnyObject {
    func handleGetTaskspaceState(_ payload: GetTaskspaceStatePayload, messageId: String) async
        -> MessageHandlingResult<TaskspaceStateResponse>
    func handleSpawnTaskspace(_ payload: SpawnTaskspacePayload, messageId: String) async
        -> MessageHandlingResult<SpawnTaskspaceResponse>
    func handleUpdateTaskspace(_ payload: UpdateTaskspacePayload, messageId: String) async
        -> MessageHandlingResult<EmptyResponse>
    func handleLogProgress(_ payload: LogProgressPayload, messageId: String) async
        -> MessageHandlingResult<EmptyResponse>
    func handleSignalUser(_ payload: SignalUserPayload, messageId: String) async
        -> MessageHandlingResult<EmptyResponse>
}

/// Empty response type for messages that don't return data
struct EmptyResponse: Codable {}

// MARK: - IPC Manager

class IpcManager: ObservableObject {
    @Published var isConnected = false
    @Published var error: String?

    private var clientProcess: Process?
    private var inputPipe: Pipe?
    private var delegates: [IpcMessageDelegate] = []

    private static var nextInstanceId = 1
    private let instanceId: Int

    init() {
        self.instanceId = IpcManager.nextInstanceId
        IpcManager.nextInstanceId += 1
        Logger.shared.log("IpcManager[\(instanceId)]: Created")
    }

    deinit {
        Logger.shared.log("IpcManager[\(instanceId)]: Cleaning up - terminating client process")
        clientProcess?.terminate()
        inputPipe = nil
    }

    // MARK: - Delegate Management

    func addDelegate(_ delegate: IpcMessageDelegate) {
        delegates.append(delegate)
        Logger.shared.log(
            "IpcManager[\(instanceId)]: Added delegate, now have \(delegates.count) delegates")
    }

    func removeDelegate(_ delegate: IpcMessageDelegate) {
        delegates.removeAll { $0 === delegate }
        Logger.shared.log(
            "IpcManager[\(instanceId)]: Removed delegate, now have \(delegates.count) delegates")
    }

    func startClient(mcpServerPath: String) {
        guard clientProcess == nil else { return }

        error = nil
        Logger.shared.log("IpcManager[\(instanceId)]: Starting symposium-mcp client...")
        Logger.shared.log("IpcManager[\(instanceId)]: Path: \(mcpServerPath)")
        Logger.shared.log("IpcManager[\(instanceId)]: Command: \(mcpServerPath) client")

        DispatchQueue.global(qos: .userInitiated).async {
            self.launchClient(mcpServerPath: mcpServerPath)
        }
    }

    func stopClient() {
        clientProcess?.terminate()
        clientProcess = nil
        inputPipe = nil

        DispatchQueue.main.async {
            self.isConnected = false
        }
    }

    private func launchClient(mcpServerPath: String) {
        let process = Process()

        // Use shell to handle PATH resolution automatically
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "\(mcpServerPath) client"]

        // Set up pipes for stdin/stdout/stderr
        let inputPipe = Pipe()
        let outputPipe = Pipe()

        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        self.inputPipe = inputPipe

        do {
            try process.run()
            self.clientProcess = process

            DispatchQueue.main.async {
                self.isConnected = true
                Logger.shared.log(
                    "IpcManager[\(self.instanceId)]: Client process started successfully")
                Logger.shared.log(
                    "IpcManager[\(self.instanceId)]: isConnected set to \(self.isConnected)")
            }

            // Set up continuous message reading
            self.setupMessageReader(outputPipe: outputPipe)

            // Monitor process termination
            process.waitUntilExit()

            DispatchQueue.main.async {
                self.isConnected = false
                Logger.shared.log(
                    "IpcManager[\(self.instanceId)]: Client process exited with status \(process.terminationStatus)"
                )
                if process.terminationStatus != 0 {
                    self.error = "Client exited with status \(process.terminationStatus)"
                }
            }

        } catch {
            DispatchQueue.main.async {
                self.error = "Failed to start client: \(error.localizedDescription)"
                Logger.shared.log(
                    "IpcManager[\(self.instanceId)]: Error starting client: \(error.localizedDescription)"
                )
            }
        }
    }

    private func setupMessageReader(outputPipe: Pipe) {
        let fileHandle = outputPipe.fileHandleForReading

        DispatchQueue.global(qos: .background).async {
            var buffer = Data()

            while self.clientProcess != nil {
                let chunk = fileHandle.availableData
                if chunk.isEmpty {
                    break  // Process ended
                }

                buffer.append(chunk)

                // Process complete lines (messages are newline-delimited)
                while let newlineRange = buffer.range(of: Data([0x0A])) {  // \n
                    let lineData = buffer.subdata(in: 0..<newlineRange.lowerBound)
                    buffer.removeSubrange(0..<newlineRange.upperBound)

                    if let lineString = String(data: lineData, encoding: .utf8), !lineString.isEmpty
                    {
                        self.handleIncomingMessage(lineString)
                    }
                }
            }
        }
    }

    private func handleIncomingMessage(_ messageString: String) {
        Logger.shared.log("IpcManager[\(instanceId)]: Received message: \(messageString)")

        guard let messageData = messageString.data(using: .utf8) else {
            Logger.shared.log("IpcManager[\(instanceId)]: Failed to convert message to data")
            return
        }

        do {
            let message = try JSONDecoder().decode(IPCMessage.self, from: messageData)

            switch message.type {
            case "get_taskspace_state":
                handleGetTaskspaceState(message: message)
            case "spawn_taskspace":
                handleSpawnTaskspace(message: message)
            case "update_taskspace":
                handleUpdateTaskspace(message: message)
            case "log_progress":
                handleLogProgress(message: message)
            case "signal_user":
                handleSignalUser(message: message)
            case "register_taskspace_window":
                handleRegisterTaskspaceWindow(message: message)
            default:
                Logger.shared.log(
                    "IpcManager[\(instanceId)]: Unknown message type: \(message.type)")
            }

        } catch {
            Logger.shared.log("IpcManager[\(instanceId)]: Failed to parse message: \(error)")
        }
    }

    private func handleGetTaskspaceState(message: IPCMessage) {
        Task {
            do {
                let payloadData = try JSONEncoder().encode(message.payload)
                let payload = try JSONDecoder().decode(
                    GetTaskspaceStatePayload.self, from: payloadData)
                Logger.shared.log(
                    "IpcManager[\(instanceId)]: Get taskspace state for UUID: \(payload.taskspaceUuid)"
                )

                // Try each delegate until one handles the message
                for delegate in delegates {
                    let result = await delegate.handleGetTaskspaceState(
                        payload, messageId: message.id)
                    if case .handled(let responseData) = result {
                        sendResponse(to: message.id, success: true, data: responseData)
                        return
                    }
                }

                // No delegate handled the message
                Logger.shared.log(
                    "IpcManager[\(instanceId)]: No delegate handled get_taskspace_state for UUID: \(payload.taskspaceUuid)"
                )
                sendResponse(
                    to: message.id, success: false, data: nil as EmptyResponse?,
                    error: "Taskspace not found")

            } catch {
                Logger.shared.log(
                    "IpcManager[\(instanceId)]: Failed to parse get_taskspace_state payload: \(error)"
                )
                sendResponse(
                    to: message.id, success: false, data: nil as TaskspaceStateResponse?,
                    error: "Invalid payload")
            }
        }
    }

    private func handleSpawnTaskspace(message: IPCMessage) {
        Task {
            do {
                let payloadData = try JSONEncoder().encode(message.payload)
                let payload = try JSONDecoder().decode(
                    SpawnTaskspacePayload.self, from: payloadData)
                Logger.shared.log(
                    "IpcManager[\(instanceId)]: Spawn taskspace: \(payload.name) in \(payload.projectPath)"
                )

                // Try each delegate until one handles the message
                for delegate in delegates {
                    let result = await delegate.handleSpawnTaskspace(payload, messageId: message.id)
                    if case .handled(let responseData) = result {
                        sendResponse(to: message.id, success: true, data: responseData)
                        return
                    }
                }

                // No delegate handled the message
                Logger.shared.log(
                    "IpcManager[\(instanceId)]: No delegate handled spawn_taskspace for project: \(payload.projectPath)"
                )
                sendResponse(
                    to: message.id, success: false, data: nil as SpawnTaskspaceResponse?,
                    error: "Project not found")

            } catch {
                Logger.shared.log(
                    "IpcManager[\(instanceId)]: Failed to parse spawn_taskspace payload: \(error)")
                sendResponse(
                    to: message.id, success: false, data: nil as SpawnTaskspaceResponse?,
                    error: "Invalid payload")
            }
        }
    }

    private func handleUpdateTaskspace(message: IPCMessage) {
        Task {
            do {
                let payloadData = try JSONEncoder().encode(message.payload)
                let payload = try JSONDecoder().decode(
                    UpdateTaskspacePayload.self, from: payloadData)
                Logger.shared.log(
                    "IpcManager[\(instanceId)]: Update taskspace \(payload.taskspaceUuid): \(payload.name)"
                )

                // Try each delegate until one handles the message
                for delegate in delegates {
                    let result = await delegate.handleUpdateTaskspace(
                        payload, messageId: message.id)
                    if case .handled(let responseData) = result {
                        sendResponse(to: message.id, success: true, data: responseData)
                        return
                    }
                }

                // No delegate handled the message
                Logger.shared.log(
                    "IpcManager[\(instanceId)]: No delegate handled update_taskspace message")
                sendResponse(
                    to: message.id, success: false, data: nil as String?,
                    error: "No handler available")

            } catch {
                Logger.shared.log(
                    "IpcManager[\(instanceId)]: Failed to parse update_taskspace payload: \(error)")
                sendResponse(
                    to: message.id, success: false, data: nil as String?, error: "Invalid payload")
            }
        }
    }

    private func handleLogProgress(message: IPCMessage) {
        Task {
            do {
                let payloadData = try JSONEncoder().encode(message.payload)
                let payload = try JSONDecoder().decode(LogProgressPayload.self, from: payloadData)
                Logger.shared.log(
                    "IpcManager[\(instanceId)]: Log progress for \(payload.taskspaceUuid): \(payload.message)"
                )

                // Try each delegate until one handles the message
                for delegate in delegates {
                    let result = await delegate.handleLogProgress(payload, messageId: message.id)
                    if case .handled(let responseData) = result {
                        sendResponse(to: message.id, success: true, data: responseData)
                        return
                    }
                }

                // No delegate handled the message
                Logger.shared.log(
                    "IpcManager[\(instanceId)]: No delegate handled log_progress for UUID: \(payload.taskspaceUuid)"
                )
                sendResponse(
                    to: message.id, success: false, data: nil as EmptyResponse?,
                    error: "Taskspace not found")

            } catch {
                Logger.shared.log(
                    "IpcManager[\(instanceId)]: Failed to parse log_progress payload: \(error)")
                sendResponse(
                    to: message.id, success: false, data: nil as EmptyResponse?,
                    error: "Invalid payload")
            }
        }
    }

    private func handleSignalUser(message: IPCMessage) {
        Task {
            do {
                let payloadData = try JSONEncoder().encode(message.payload)
                let payload = try JSONDecoder().decode(SignalUserPayload.self, from: payloadData)
                Logger.shared.log(
                    "IpcManager[\(instanceId)]: Signal user for \(payload.taskspaceUuid): \(payload.message)"
                )

                // Try each delegate until one handles the message
                for delegate in delegates {
                    let result = await delegate.handleSignalUser(payload, messageId: message.id)
                    if case .handled(let responseData) = result {
                        sendResponse(to: message.id, success: true, data: responseData)
                        return
                    }
                }

                // No delegate handled the message
                Logger.shared.log(
                    "IpcManager[\(instanceId)]: No delegate handled signal_user for UUID: \(payload.taskspaceUuid)"
                )
                sendResponse(
                    to: message.id, success: false, data: nil as EmptyResponse?,
                    error: "Taskspace not found")

            } catch {
                Logger.shared.log(
                    "IpcManager[\(instanceId)]: Failed to parse signal_user payload: \(error)")
                sendResponse(
                    to: message.id, success: false, data: nil as EmptyResponse?,
                    error: "Invalid payload")
            }
        }
    }

    private func handleRegisterTaskspaceWindow(message: IPCMessage) {
        Task {
            do {
                let payloadData = try JSONEncoder().encode(message.payload)
                let payload = try JSONDecoder().decode(
                    RegisterTaskspaceWindowPayload.self, from: payloadData)
                Logger.shared.log(
                    "IpcManager[\(instanceId)]: Register window containing '\(payload.windowTitle)' for taskspace \(payload.taskspaceUuid)"
                )

                if let windowID = findWindowBySubstring(payload.windowTitle) {
                    Logger.shared.log(
                        "IpcManager[\(instanceId)]: Found window \(windowID) for taskspace \(payload.taskspaceUuid)"
                    )

                    // Store association via delegate
                    var success = false
                    for delegate in delegates {
                        if let projectManager = delegate as? ProjectManager,
                            projectManager.associateWindow(windowID, with: payload.taskspaceUuid)
                        {
                            success = true
                            break
                        }
                    }

                    if success {
                        sendResponse(to: message.id, success: true, data: ["success": true])
                    } else {
                        sendResponse(
                            to: message.id, success: false, data: nil as EmptyResponse?,
                            error: "Failed to associate window")
                    }
                } else {
                    Logger.shared.log(
                        "IpcManager[\(instanceId)]: Window not found containing: \(payload.windowTitle)"
                    )
                    sendResponse(
                        to: message.id, success: false, data: nil as EmptyResponse?,
                        error: "Window not found")
                }

            } catch {
                Logger.shared.log(
                    "IpcManager[\(instanceId)]: Failed to parse register_taskspace_window payload: \(error)"
                )
                sendResponse(
                    to: message.id, success: false, data: nil as EmptyResponse?,
                    error: "Invalid payload")
            }
        }
    }

    private func findWindowBySubstring(_ targetSubstring: String) -> CGWindowID? {
        let options = CGWindowListOption([.optionOnScreenOnly, .excludeDesktopElements])
        let windowList =
            CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []

        for dict in windowList {
            guard let windowID = dict[kCGWindowNumber as String] as? CGWindowID,
                dict[kCGWindowLayer as String] as? Int == 0  // Normal windows only
            else {
                continue
            }

            // Get window title from CGWindow info
            let title = dict[kCGWindowName as String] as? String ?? ""

            if title.contains(targetSubstring) {
                return windowID
            }
        }

        return nil
    }

    // MARK: - Response Sending (for delegates)

    func sendResponse<T: Codable>(
        to messageId: String, success: Bool, data: T? = nil, error: String? = nil
    ) {
        guard let inputPipe = self.inputPipe else {
            Logger.shared.log("IpcManager[\(instanceId)]: Cannot send response - no input pipe")
            return
        }

        do {
            let responseData: JsonBlob?
            if let data = data {
                let encodedData = try JSONEncoder().encode(data)
                responseData = try JSONDecoder().decode(JsonBlob.self, from: encodedData)
            } else {
                responseData = nil
            }

            // Build response payload as JsonBlob directly
            var responseFields: [JsonBlob.PropertyKey: JsonBlob] = [
                JsonBlob.PropertyKey(stringValue: "success"): .boolean(success)
            ]

            if let error = error {
                responseFields[JsonBlob.PropertyKey(stringValue: "error")] = .string(error)
            }

            if let responseData = responseData {
                responseFields[JsonBlob.PropertyKey(stringValue: "data")] = responseData
            }

            let responseMessage = IPCMessage(
                type: "response",
                payload: .object(responseFields),
                id: messageId,
                sender: MessageSender(
                    workingDirectory: "/tmp",  // Generic path for Symposium app messages
                    taskspaceUuid: nil,        // Response messages don't have specific taskspace
                    shellPid: nil              // Symposium app doesn't have shell PID
                )
            )

            let messageData = try JSONEncoder().encode(responseMessage)
            var messageString = String(data: messageData, encoding: .utf8) ?? ""
            messageString += "\n"

            if let stringData = messageString.data(using: String.Encoding.utf8) {
                inputPipe.fileHandleForWriting.write(stringData)
                Logger.shared.log("IpcManager[\(instanceId)]: Sent response to \(messageId)")
            }

        } catch {
            Logger.shared.log("IpcManager[\(instanceId)]: Failed to send response: \(error)")
        }
    }

    func sendBroadcastMessage<T: Codable>(type: String, payload: T) {
        guard let inputPipe = self.inputPipe else {
            Logger.shared.log(
                "IpcManager[\(instanceId)]: Cannot send broadcast message - no input pipe")
            return
        }

        do {
            // Convert payload to JsonBlob
            let encodedPayload = try JSONEncoder().encode(payload)
            let jsonBlobPayload = try JSONDecoder().decode(JsonBlob.self, from: encodedPayload)

            let message = IPCMessage(
                type: type,
                payload: jsonBlobPayload,
                id: UUID().uuidString,
                sender: MessageSender(
                    workingDirectory: "/tmp",  // Generic path for Symposium app broadcasts
                    taskspaceUuid: nil,        // Broadcast messages don't have specific taskspace
                    shellPid: nil              // Symposium app doesn't have shell PID
                )
            )

            let messageData = try JSONEncoder().encode(message)
            var messageString = String(data: messageData, encoding: .utf8) ?? ""
            messageString += "\n"

            if let stringData = messageString.data(using: String.Encoding.utf8) {
                inputPipe.fileHandleForWriting.write(stringData)
                Logger.shared.log("IpcManager[\(instanceId)]: Sent broadcast message: \(type)")
            }

        } catch {
            Logger.shared.log(
                "IpcManager[\(instanceId)]: Failed to send broadcast message: \(error)")
        }
    }
}
