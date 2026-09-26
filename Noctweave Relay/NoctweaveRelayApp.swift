//
//  NoctweaveRelayApp.swift
//  Noctweave Relay
//
//  Created by Luiz Fernando Widmer Neto on 27/12/25.
//

import SwiftUI
import Combine
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
    @StateObject private var support = AppSupportStore.shared

#if canImport(AppKit)
    @NSApplicationDelegateAdaptor(RelayAppDelegate.self) private var appDelegate
#endif
    @ObservedObject private var uiPreferences = RelayUIPreferences.shared

    private var appearance: NoctweaveAppearanceMode {
        NoctweaveAppearanceMode(rawValue: uiPreferences.appearanceRaw) ?? .system
    }

    @StateObject private var session = RelayApplicationSession()

    var body: some Scene {
        WindowGroup {
            ContentView(model: session.model)
                .id(ObjectIdentifier(session.model))
                .tint(.noctweaveCoral)
                .preferredColorScheme(appearance.preferredColorScheme)
        }
    }
}

@MainActor
private final class RelayApplicationSession: ObservableObject {
    @Published private(set) var model = ServerViewModel()
    init() { connectReset() }
    private func connectReset() {
        model.onResetCompleted = { [weak self] in
            guard let self else { return }
            RelayUIPreferences.shared.resetInMemory()
            self.model = ServerViewModel()
            self.connectReset()
        }
    }
}
