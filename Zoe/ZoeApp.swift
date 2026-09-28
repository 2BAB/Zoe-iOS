import SwiftUI

@main
struct ZoeApp: App {
    @State private var model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
        #if os(macOS)
        .defaultSize(width: 1000, height: 760)
        #endif
    }
}
