//
//  NoctweaveRelayApp.swift
//  Noctweave Relay
//
//  Created by Luiz Fernando Widmer Neto on 27/12/25.
//

import SwiftUI

@main
struct NoctweaveRelayApp: App {
    @AppStorage("noctweave.relay.appearance") private var appearanceRaw = NoctweaveAppearanceMode.system.rawValue

    private var appearance: NoctweaveAppearanceMode {
        NoctweaveAppearanceMode(rawValue: appearanceRaw) ?? .system
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .tint(.noctweaveCoral)
                .preferredColorScheme(appearance.preferredColorScheme)
        }
    }
}
