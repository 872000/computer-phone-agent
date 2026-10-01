//
//  ContentView.swift
//  PhoneAgent
//
//  Created by Rounak Jain on 5/30/25.
//

import SwiftUI
import Security

struct ContentView: View {
    enum AppState {
        case rpcBridge
        case enterAPIKey
        case prompt(String)
    }

    private static func initialAppState() -> AppState {
        if ProcessInfo.processInfo.arguments.contains("--phoneagent-rpc-bridge") {
            .rpcBridge
        } else {
            KeychainHelper.load().map { .prompt($0) } ?? .enterAPIKey
        }
    }

    @State private var state: AppState = Self.initialAppState()
    let rpcClient: PhoneAgentRPCClient

    var body: some View {
        switch state {
        case .rpcBridge:
            RPCBridgeModeView()
        case .enterAPIKey:
            EnterAPIKeyView { key in
                KeychainHelper.save(key: key)
                state = .prompt(key)
            }
        case .prompt(let key):
            PromptView(rpcClient: rpcClient, deleteKey: deleteKey)
                .onAppear {
                    Task {
                        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
                        await rpcClient.setOpenAIAPIKey(trimmed)
                    }
                }
        }
    }

    private func deleteKey() {
        KeychainHelper.delete()
        state = .enterAPIKey
    }
}
