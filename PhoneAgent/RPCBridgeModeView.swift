//
//  RPCBridgeModeView.swift
//  PhoneAgent
//
//  Shown when the PhoneAgent app is launched as a UI-test hosted RPC bridge
//  (e.g. for the phoneagent skill), where an OpenAI API key is not needed.
//

import SwiftUI

struct RPCBridgeModeView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "rectangle.and.pencil.and.ellipsis")
                .font(.system(size: 44))
                .foregroundStyle(.tint)

            VStack(spacing: 10) {
                Text("PhoneAgent RPC Bridge")
                    .font(.title2)
                    .fontWeight(.bold)

                Text("This session is running in bridge mode for automation.")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 10) {
                Label("Connect from your Mac at 127.0.0.1:45678", systemImage: "network")
                Label("Use the `rpc.py` helper to send JSON-RPC calls", systemImage: "terminal")
            }
            .font(.footnote)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(.separator, lineWidth: 1.0/UIScreen.main.scale)
            )

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 40)
    }
}

#Preview {
    RPCBridgeModeView()
}

