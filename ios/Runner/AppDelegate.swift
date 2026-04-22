import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // VIII.17 — register the Save-to-Files method channel so the Dart
    // side's `SaveToFiles.save()` can invoke
    // UIDocumentPickerViewController(forExporting:).
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "SaveToFilesPlugin") {
      SaveToFilesPlugin.register(
        with: registrar,
        rootViewController: window?.rootViewController
      )
    }
  }
}
