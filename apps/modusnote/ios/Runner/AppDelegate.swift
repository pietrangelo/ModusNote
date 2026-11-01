import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let privacyCover = PrivacyCover()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    privacyCover.start()
    excludeVaultsFromBackup()
    // Password expiry reminders show while the app is open too.
    UNUserNotificationCenter.current().delegate = self as? UNUserNotificationCenterDelegate
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "SensitiveClipboard") {
      SensitiveClipboard.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ScreenAwake") {
      ScreenAwake.register(with: registrar)
    }
  }

  /// Vaults, recordings and the vault list live in Application Support,
  /// which iOS copies to iCloud and computer backups. A restored copy would
  /// sign as this device on another phone, and the backup would carry the
  /// sealed identity off the device: keep the whole folder out, as Android's
  /// allowBackup="false" does.
  private func excludeVaultsFromBackup() {
    let files = FileManager.default
    guard var folder = files.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    else { return }
    try? files.createDirectory(at: folder, withIntermediateDirectories: true)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try? folder.setResourceValues(values)
  }
}

/// Keeps the screen on while a recipe is open in cooking mode. iOS turns
/// the idle timer back on by itself when the app leaves the foreground.
final class ScreenAwake {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "run.serv.modus/screen", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { call, result in
      guard call.method == "keepOn",
        let args = call.arguments as? [String: Any],
        let on = args["on"] as? Bool
      else { return result(FlutterMethodNotImplemented) }
      UIApplication.shared.isIdleTimerDisabled = on
      result(nil)
    }
  }
}

/// Copies a password so it stays on this device and leaves by itself:
/// never handed to Universal Clipboard, gone after the expiry even if the
/// app is killed before it clears it.
final class SensitiveClipboard {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "run.serv.modus/clipboard", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { call, result in
      guard call.method == "copySecret",
        let args = call.arguments as? [String: Any],
        let text = args["text"] as? String,
        let seconds = args["seconds"] as? Int
      else { return result(FlutterMethodNotImplemented) }
      UIPasteboard.general.setItems(
        [["public.utf8-plain-text": text]],
        options: [
          .localOnly: true,
          .expirationDate: Date(timeIntervalSinceNow: TimeInterval(seconds)),
        ])
      result(nil)
    }
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
