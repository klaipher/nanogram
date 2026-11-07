import UIKit
import Display

// A bare app hosting `DisplayAccessibilityTests`. The tests need a running UIApplication: without one,
// `CADisplayLink(target:selector:)` returns nil and `ListViewImpl.init` traps. Class names match
// `//Tests/Common:Main`'s `UIApplicationMain(…, @"Application", @"AppDelegate")`. Display is imported so the host
// links it (and AsyncDisplayKit) and the test bundle uses the host's copy.

private let linkDisplay: Any.Type = ListViewImpl.self

@objc(Application)
final class Application: UIApplication {
}

/// Scene-based: an app built with the iOS 27 SDK that does not adopt the scene lifecycle traps at launch.
@objc(AppDelegate)
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

@objc(SceneDelegate)
final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else {
            return
        }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        self.window = window
    }
}
