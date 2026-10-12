import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let privacyCover = PrivacyCover()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    privacyCover.start()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}

/// Puts a plain cover over the window whenever its scene stops being
/// active, so the app switcher shows (and snapshots) no decrypted note.
/// iOS offers no way to block screenshots themselves.
///
/// It listens to scene notifications rather than overriding
/// FlutterSceneDelegate, which forwards the lifecycle to the engine.
final class PrivacyCover {
  private var covers: [ObjectIdentifier: UIView] = [:]
  private var observers: [NSObjectProtocol] = []

  func start() {
    let center = NotificationCenter.default
    observers = [
      center.addObserver(
        forName: UIScene.willDeactivateNotification, object: nil, queue: .main
      ) { [weak self] note in
        if let scene = note.object as? UIWindowScene { self?.cover(scene) }
      },
      center.addObserver(
        forName: UIScene.didActivateNotification, object: nil, queue: .main
      ) { [weak self] note in
        if let scene = note.object as? UIWindowScene { self?.uncover(scene) }
      },
    ]
  }

  private func cover(_ scene: UIWindowScene) {
    let key = ObjectIdentifier(scene)
    guard covers[key] == nil, let window = scene.windows.first else { return }
    let view = UIView(frame: window.bounds)
    view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    // Deep Void, the app's background.
    view.backgroundColor = UIColor(
      red: 0x09 / 255.0, green: 0x0C / 255.0, blue: 0x15 / 255.0, alpha: 1)
    window.addSubview(view)
    covers[key] = view
  }

  private func uncover(_ scene: UIWindowScene) {
    covers.removeValue(forKey: ObjectIdentifier(scene))?.removeFromSuperview()
  }
}
