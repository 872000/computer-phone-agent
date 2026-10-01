//
//  PhoneAgent.swift
//  PhoneAgent
//
//  Created by Rounak Jain on 5/31/25.
//

import CoreGraphics
import Foundation
import UserNotifications
import XCTest

extension PhoneAgent {
    enum Error: Swift.Error, LocalizedError {
        case invalidCommand(String)
        case invalidParams(String)
        case invalidTool(name: String?, message: String)
        case noAppFound
        case apiNotConfigured
        case serverShutDown

        var errorDescription: String? {
            switch self {
            case .invalidCommand(let command):
                "Unsupported command: \(command)"
            case .invalidParams(let message):
                "Invalid params: \(message)"
            case .invalidTool(let name, let message):
                "Invalid tool \(name ?? "unknown"): \(message)"
            case .noAppFound:
                "No app found to interact with."
            case .apiNotConfigured:
                "No API key found"
            case .serverShutDown:
                "RPC server is no longer available."
            }
        }
    }
}

extension PhoneAgent {
    func uiCoordinate(in app: XCUIApplication, at point: CGPoint) -> XCUICoordinate {
        // Root (0,0) of the screen
        let root = app.coordinate(withNormalizedOffset: .zero)
        return root.withOffset(CGVector(dx: point.x, dy: point.y))
    }

    func uiTap(
        in app: XCUIApplication,
        at point: CGPoint,
        count: Int,
        longPress: Bool,
        longPressDuration: TimeInterval
    ) {
        let coord = uiCoordinate(in: app, at: point)
        if longPress {
            coord.press(forDuration: longPressDuration)
            return
        }
        if count == 2 {
            coord.doubleTap()
            return
        }
        if count <= 1 {
            coord.tap()
            return
        }
        for _ in 0..<count {
            coord.tap()
        }
    }

    func uiDrag(
        in app: XCUIApplication,
        from: CGPoint,
        to: CGPoint,
        pressDuration: TimeInterval
    ) {
        let start = uiCoordinate(in: app, at: from)
        let end = uiCoordinate(in: app, at: to)
        start.press(forDuration: pressDuration, thenDragTo: end)
    }
}

// JSON-RPC command execution.
extension PhoneAgent {
    private enum Method: String {
        case getTree = "get_tree"
        case getScreenImage = "get_screen_image"
        case getContext = "get_context"
        case tap = "tap"
        case tapElement = "tap_element"
        case enterText = "enter_text"
        case scroll = "scroll"
        case swipe = "swipe"
        case openApp = "open_app"
        case setOpenAIAPIKey = "set_api_key"
        case submitPrompt = "submit_prompt"
        case stop = "stop"
    }

    @MainActor
    func handleRPC(method rawMethod: String, parameters: [String: Any]) throws -> (result: Any, shouldStop: Bool) {
        guard let method = Method(rawValue: rawMethod) else {
            throw Error.invalidCommand(rawMethod)
        }

        switch method {
        case .getTree:
            return (["tree": try accessibilityTree()], false)
        case .getScreenImage:
            return (screenImagePayload(), false)
        case .getContext:
            var payload = screenImagePayload()
            payload["tree"] = try accessibilityTree()
            return (payload, false)
        case .tap:
            let x = try numberValue(for: "x", in: parameters)
            let y = try numberValue(for: "y", in: parameters)
            try tap(x: x, y: y)
            return (["tree": try accessibilityTree()], false)
        case .tapElement:
            let coordinate = try stringValue(for: "coordinate", in: parameters)
            let count = parameters["count"] as? Int ?? 1
            let longPress = parameters["longPress"] as? Bool ?? false
            try tapElement(rect: coordinate, count: count, longPress: longPress)
            return ([
                "coordinate": coordinate,
                "count": (longPress ? 1 : count),
                "longPress": longPress,
                "tree": try accessibilityTree()
            ], false)
        case .enterText:
            let coordinate = try stringValue(for: "coordinate", in: parameters)
            let text = try stringValue(for: "text", in: parameters)
            try enterText(rect: coordinate, text: text)
            return ([
                "coordinate": coordinate,
                "tree": try accessibilityTree()
            ], false)
        case .scroll:
            let x = try numberValue(for: "x", in: parameters)
            let y = try numberValue(for: "y", in: parameters)
            let distanceX = try numberValue(for: "distanceX", in: parameters)
            let distanceY = try numberValue(for: "distanceY", in: parameters)
            try scroll(x: x, y: y, distanceX: distanceX, distanceY: distanceY)
            return (["tree": try accessibilityTree()], false)
        case .swipe:
            let x = try numberValue(for: "x", in: parameters)
            let y = try numberValue(for: "y", in: parameters)
            let directionText = try stringValue(for: "direction", in: parameters).lowercased()
            guard let direction = SwipeDirection(rawValue: directionText) else {
                throw Error.invalidParams("direction must be one of: up, down, left, right")
            }
            try swipe(x: x, y: y, direction: direction)
            return (["tree": try accessibilityTree()], false)
        case .openApp:
            let bundleIdentifier = try stringValue(for: "bundle_identifier", in: parameters)
            try openApp(bundleIdentifier: bundleIdentifier)
            return ([
                "bundle_identifier": bundleIdentifier,
                "tree": try accessibilityTree()
            ], false)
        case .setOpenAIAPIKey:
            let apiKey = try stringValue(for: "api_key", in: parameters)
            let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw Error.invalidParams("api_key is required")
            }
            api = OpenAIService(with: trimmed)
            return (["ok": true], false)
        case .submitPrompt:
            let prompt = try stringValue(for: "prompt", in: parameters)
            let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw Error.invalidParams("prompt is required")
            }
            guard api != nil else {
                throw Error.apiNotConfigured
            }
            guard task == nil else {
                throw Error.invalidParams("Agent is already running")
            }

            // Only request notification permission when the in-app agent flow is used
            // (so pure RPC automation doesn't get blocked by the system prompt).
            notificationCenter.requestNotificationPermission()
            task = Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.task = nil }
                do {
                    try await self.submit(trimmed)
                } catch {
                    print("Error processing prompt: \(error)")
                }
            }
            return (["started": true], false)
        case .stop:
            return ([:], true)
        }
    }

    @MainActor
    private func accessibilityTree() throws -> String {
        guard let app else {
            throw Error.noAppFound
        }
        return app.accessibilityTree()
    }

    @MainActor
    private func tap(point: CGPoint, count: Int, longPress: Bool) throws {
        guard let app else {
            throw Error.noAppFound
        }
        guard count >= 1 else {
            throw Error.invalidParams("count must be >= 1")
        }
        uiTap(
            in: app,
            at: point,
            count: count,
            longPress: longPress,
            longPressDuration: 0.5
        )
    }

    @MainActor
    private func openApp(bundleIdentifier: String) throws {
        guard !bundleIdentifier.isEmpty else {
            throw Error.invalidParams("bundle_identifier is required")
        }
        guard isValidBundleIdentifier(bundleIdentifier) else {
            throw Error.invalidParams("bundle_identifier '\(bundleIdentifier)' is not a valid bundle identifier")
        }

        let target = XCUIApplication(bundleIdentifier: bundleIdentifier)
        target.activate()

        guard target.wait(for: .runningForeground, timeout: 8) else {
            throw Error.invalidParams("App '\(bundleIdentifier)' did not reach foreground state")
        }

        self.app = target
    }

    @MainActor
    private func screenImagePayload() -> [String: Any] {
        let screenshotData = XCUIScreen.main.screenshot().pngRepresentation
        var payload: [String: Any] = [
            "screenshot_base64": screenshotData.base64EncodedString()
        ]
        if let dimensions = pngDimensions(from: screenshotData) {
            payload["metadata"] = [
                "width": dimensions.width,
                "height": dimensions.height
            ]
        }
        return payload
    }

    private func pngDimensions(from data: Data) -> (width: Int, height: Int)? {
        let pngSignature = Data([137, 80, 78, 71, 13, 10, 26, 10])
        guard data.count >= 24, data.starts(with: pngSignature) else {
            return nil
        }
        guard data.subdata(in: 12..<16) == Data("IHDR".utf8) else {
            return nil
        }
        guard let width = readUInt32BigEndian(in: data, offset: 16),
              let height = readUInt32BigEndian(in: data, offset: 20) else {
            return nil
        }
        return (Int(width), Int(height))
    }

    private func readUInt32BigEndian(in data: Data, offset: Int) -> UInt32? {
        guard data.count >= offset + 4 else {
            return nil
        }
        return data[offset..<(offset + 4)].reduce(UInt32(0)) { partial, byte in
            (partial << 8) | UInt32(byte)
        }
    }

    private func numberValue(for key: String, in parameters: [String: Any]) throws -> CGFloat {
        guard let value = parameters[key] else {
            throw Error.invalidParams("missing parameter '\(key)'")
        }
        if let number = value as? NSNumber {
            return CGFloat(truncating: number)
        }
        if let text = value as? String, let number = Double(text) {
            return CGFloat(number)
        }
        throw Error.invalidParams("parameter '\(key)' must be a number")
    }

    private func stringValue(for key: String, in parameters: [String: Any]) throws -> String {
        guard let value = parameters[key] else {
            throw Error.invalidParams("missing parameter '\(key)'")
        }
        guard let text = value as? String else {
            throw Error.invalidParams("parameter '\(key)' must be a string")
        }
        return text
    }

    private func centerPoint(forCoordinateString coordinate: String) throws -> CGPoint {
        // Coordinate string format should match XCUI debugDescription frames:
        //   "{{x, y}, {w, h}}"
        guard coordinate.hasPrefix("{{"), coordinate.hasSuffix("}}") else {
            throw Error.invalidParams("coordinate must look like {{x, y}, {w, h}}; got '\(coordinate)'")
        }
        let rect = NSCoder.cgRect(for: coordinate)
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    private func isValidBundleIdentifier(_ bundleId: String) -> Bool {
        let pattern = #"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$"#
        return bundleId.range(of: pattern, options: .regularExpression) != nil
    }
}

// Mode 1: internal agent loop (model calls happen from the UI test target).
extension PhoneAgent {
    @MainActor
    func submit(_ prompt: String) async throws {
        try await recurse(with: OpenAIRequest(with: prompt, accessibilityTree: app.map { $0.accessibilityTree() }))
    }

    @MainActor
    private func recurse(with request: OpenAIRequest) async throws {
        guard let api else {
            throw Error.apiNotConfigured
        }
        var request = request
        let response = try await api.send(request)
        guard let last = response.output.last else { fatalError("No response received.") }
        print("Received message \(last)")
        request.input = []
        request.previousResponseID = response.id
        lastRequest = request
        let output: String
        switch last {
        case .functionCall(let id, let functionCall):
            do {
                switch functionCall {
                case let .tapElement(coordinate, count, longPress):
                    try tapElement(rect: coordinate, count: count, longPress: longPress)
                case .fetchAccessibilityTree:
                    print("Getting current accessibility tree")
                case let .enterText(coordinate, text):
                    try enterText(rect: coordinate, text: text)
                case .openApp(let bundleIdentifier):
                    try openApp(bundleIdentifier: bundleIdentifier)
                case let .scroll(x: x, y: y, distanceX: distanceX, distanceY: distanceY):
                    try scroll(x: x, y: y, distanceX: distanceX, distanceY: distanceY)
                case let .swipe(x: x, y: y, direction: direction):
                    try swipe(x: x, y: y, direction: direction)
                }
                guard let app else {
                    throw Error.noAppFound
                }
                output = app.accessibilityTree()
            } catch {
                output = "Error executing function call: \(error.localizedDescription)"
            }
            request.input.append(.functionCallOutput(id, output: output))
            try await recurse(with: request)
        case .message(let message):
            Task {
                do {
                    try await sendNotification(message: message.content.first { $0.type == .outputText }?.text ?? "Completed")
                } catch {
                    print(error)
                }
            }
        }
    }

}

// Tools
extension PhoneAgent {

    @MainActor
    func tap(x: CGFloat, y: CGFloat) throws {
        guard let app else {
            throw Error.noAppFound
        }
        uiTap(
            in: app,
            at: CGPoint(x: x, y: y),
            count: 1,
            longPress: false,
            longPressDuration: 0.5
        )
    }

    @MainActor
    func tapElement(rect coordinateString: String, count: Int?, longPress: Bool?) throws {
        let isLongPress = (longPress == true)
        let effectiveCount = isLongPress ? 1 : (count ?? 1)
        let center = try centerPoint(forCoordinateString: coordinateString)
        try tap(point: center, count: effectiveCount, longPress: isLongPress)
    }

    @MainActor
    func scroll(x: CGFloat, y: CGFloat, distanceX: CGFloat, distanceY: CGFloat) throws {
        guard let app else {
            throw Error.noAppFound
        }
        let from = CGPoint(x: x, y: y)
        let to = CGPoint(x: x + distanceX, y: y + distanceY)
        uiDrag(
            in: app,
            from: from,
            to: to,
            pressDuration: 0.0
        )
    }

    @MainActor
    func swipe(x: CGFloat, y: CGFloat, direction: SwipeDirection) throws {
        guard let app else {
            throw Error.noAppFound
        }
        let mid = CGPoint(x: x, y: y)

        // Root (0,0) of the screen
        let root = app.coordinate(withNormalizedOffset: .zero)

        let start = root.withOffset(CGVector(dx: mid.x, dy: mid.y))

        let end: XCUICoordinate
        switch direction {
        case .up:
            end = root.withOffset(CGVector(dx: mid.x, dy: mid.y - 100))
        case .down:
            end = root.withOffset(CGVector(dx: mid.x, dy: mid.y + 100))
        case .left:
            end = root.withOffset(CGVector(dx: mid.x - 100, dy: mid.y))
        case .right:
            end = root.withOffset(CGVector(dx: mid.x + 100, dy: mid.y))
        }

        start.press(forDuration: 0.1, thenDragTo: end)
    }

    @MainActor
    func enterText(rect: String, text: String) throws {
        guard let app else {
            throw Error.noAppFound
        }
        try tapElement(rect: rect, count: 1, longPress: false)
        let keyboard = app.keyboards.element
        let existsPredicate = NSPredicate(format: "exists == true")

        let exp = XCTNSPredicateExpectation(predicate: existsPredicate, object: keyboard)
        _ = XCTWaiter.wait(for: [exp], timeout: 2.0)
        app.typeText(text + "\n")
    }
}

extension PhoneAgent: UNUserNotificationCenterDelegate {

    private enum NotificationConstants {
        static let categoryIdentifier = "PUA_CATEGORY"
        static let replyActionIdentifier = "REPLY_ACTION"
    }

    func sendNotification(message: String) async throws {

        let replyAction = UNTextInputNotificationAction(
            identifier: NotificationConstants.replyActionIdentifier,
            title: "Reply",
            options: [],
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Type your reply..."
        )

        let category = UNNotificationCategory(
            identifier: NotificationConstants.categoryIdentifier,
            actions: [replyAction],
            intentIdentifiers: [],
            options: []
        )

        notificationCenter.setNotificationCategories([category])

        let content = UNMutableNotificationContent()
        content.title = "Phone Agent"
        content.body = message
        content.sound = .default
        content.categoryIdentifier = NotificationConstants.categoryIdentifier

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.5, repeats: false)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)

        try await notificationCenter.add(request)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        defer { completionHandler() }
        guard response.actionIdentifier == NotificationConstants.replyActionIdentifier else {
            print("Received unexpected notification response with action: \(response.actionIdentifier)")
            return
        }
        guard let textResponse = response as? UNTextInputNotificationResponse else { return }
        let userText = textResponse.userText
        handleQuickReply(text: userText)
    }

    func handleQuickReply(text: String) {
        guard var lastRequest else {
            print("No last request found.")
            return
        }
        lastRequest.input = [
            .user(text)
        ]
        Task {
            do {
                try await recurse(with: lastRequest)
            } catch {
                print(error)
            }
        }
    }
}

struct AccessibilityTreeCompressor {
    let memoryAddressRegex = try! NSRegularExpression(pattern: #"0x[0-9a-fA-F]+"#)
    func callAsFunction(_ tree: String) -> String {
        let cleaned = memoryAddressRegex.stringByReplacingMatches(
            in: tree,
            range: NSRange(tree.startIndex..., in: tree),
            withTemplate: ""
        ).replacingOccurrences(of: ", ,", with: ",")

        // Remove low-information “Other” lines
        let keptLines = cleaned
            .components(separatedBy: .newlines)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)

                // Only look at nodes that start with “Other,”
                guard trimmed.hasPrefix("Other,") else { return true }

                // Keep if it still shows anything useful
                return trimmed.contains("identifier:")
                    || trimmed.contains("label:")
                    || trimmed.contains("placeholderValue:")
            }

        return keptLines.joined(separator: "\n")
    }
}

extension XCUIApplication {
    static let treeCompressor = AccessibilityTreeCompressor()
    func accessibilityTree() -> String {
        Self.treeCompressor(debugDescription)
    }
}
