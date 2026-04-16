import SwiftUI

@main
struct StarmineMacApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.light)
                .frame(minWidth: 1220, minHeight: 760)
        }
        .defaultSize(width: 1480, height: 920)
    }
}
