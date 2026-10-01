//
//  PhoneAgentApp.swift
//  PhoneAgent
//
//  Created by Rounak Jain on 5/30/25.
//

import SwiftUI

@main
struct PhoneAgentApp: App {
    let rpcClient = PhoneAgentRPCClient()
    var body: some Scene {
        WindowGroup {
            ContentView(rpcClient: rpcClient)
        }
    }
}
