//
//  NoctweaveRelayApp.swift
//  Noctweave Relay
//
//  Created by Luiz Fernando Widmer Neto on 27/12/25.
//

import SwiftUI
#if canImport(AppKit)
import AppKit

@MainActor
private final class RelayAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        ManagedCoturnService.shared.stop()
    }
}
#endif

@main
struct NoctweaveRelayApp: App {
#if canImport(AppKit)
    @NSApplicationDelegateAdaptor(RelayAppDelegate.self) private var appDelegate
#endif
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
