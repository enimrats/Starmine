import SwiftUI
import UIKit

@main
struct StarmineiOSApp: App {
    @UIApplicationDelegateAdaptor(StarmineiOSAppDelegate.self)
    private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.light)
        }
    }
}

final class StarmineiOSAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        StarmineiOSOrientationController.supportedOrientations
    }
}

@MainActor
enum StarmineiOSOrientationController {
    static var supportedOrientations: UIInterfaceOrientationMask =
        .allButUpsideDown

    static func enterVideoFullscreen() {
        supportedOrientations = .landscape
        requestOrientationMask(.landscape)
    }

    static func exitVideoFullscreen() {
        restoreDefaultOrientationBehavior()
    }

    static func restoreDefaultOrientationBehavior() {
        supportedOrientations = .allButUpsideDown
        requestOrientationMask(.allButUpsideDown)
    }

    private static func requestOrientationMask(
        _ orientations: UIInterfaceOrientationMask
    ) {
        guard
            let windowScene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive })
        else {
            return
        }

        windowScene.windows.forEach { window in
            window.rootViewController?
                .setNeedsUpdateOfSupportedInterfaceOrientations()
        }

        windowScene.requestGeometryUpdate(
            .iOS(interfaceOrientations: orientations)
        ) { error in
            #if DEBUG
                print("[orientation] \(error.localizedDescription)")
            #endif
        }
    }
}
