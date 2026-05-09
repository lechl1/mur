import AppBundle
import SwiftUI

// This file is shared between SPM and xcode project

@main
@MainActor
struct AeroSpaceApp: App {
    // `@StateObject var = .shared` evaluates the default in a nonisolated
    // context under the macOS 14 SDK. Annotating the struct as @MainActor
    // pulls the default-value evaluation onto the main actor, where the
    // .shared singletons live. macOS 15+ SDK marks the App protocol as
    // @MainActor, making this annotation redundant — but harmless.
    @StateObject var viewModel = TrayMenuModel.shared
    @StateObject var messageModel = MessageModel.shared
    @Environment(\.openWindow) var openWindow: OpenWindowAction

    init() {
        initAppBundle()
    }

    var body: some Scene {
        menuBar(viewModel: viewModel)
        getMessageWindow(messageModel: messageModel)
            .onChange(of: messageModel.message) { message in
                if message != nil {
                    openWindow(id: messageWindowId)
                }
            }
    }
}
