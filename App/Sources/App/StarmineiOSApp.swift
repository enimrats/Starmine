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
        requestOrientation(.landscapeRight)
    }

    static func exitVideoFullscreen() {
        supportedOrientations = .allButUpsideDown
        requestOrientation(.portrait)
    }

    private static func requestOrientation(
        _ orientation: UIInterfaceOrientation
    ) {
        guard
            let windowScene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive })
        else {
            return
        }

        windowScene.windows.forEach { window in
            window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }

        windowScene.requestGeometryUpdate(
            .iOS(interfaceOrientations: UIInterfaceOrientationMask(orientation))
        ) { error in
            #if DEBUG
                print("[orientation] \(error.localizedDescription)")
            #endif
        }

        UIViewController.attemptRotationToDeviceOrientation()
    }
}

private extension UIInterfaceOrientationMask {
    init(_ orientation: UIInterfaceOrientation) {
        switch orientation {
        case .portrait:
            self = .portrait
        case .portraitUpsideDown:
            self = .portraitUpsideDown
        case .landscapeLeft:
            self = .landscapeLeft
        case .landscapeRight:
            self = .landscapeRight
        default:
            self = .allButUpsideDown
        }
    }
}
