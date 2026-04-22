import Flutter
import UIKit

/// VIII.17 — Native iOS handler for `com.imageeditor/save_to_files`.
///
/// Wraps `UIDocumentPickerViewController(forExporting:)` so the Dart
/// side can invoke "Save to Files" with a single call instead of going
/// through the full share sheet.
///
/// The handler returns:
/// - `true` when the user picked a destination + the file was saved
/// - `false` when the user cancelled the picker
/// - throws a `FlutterError` for missing args / unreadable file paths
class SaveToFilesPlugin: NSObject {
    private weak var rootViewController: UIViewController?
    private var pendingResult: FlutterResult?
    private var pendingDelegate: PickerDelegate?

    init(rootViewController: UIViewController?) {
        self.rootViewController = rootViewController
    }

    static func register(with registrar: FlutterPluginRegistrar, rootViewController: UIViewController?) {
        let instance = SaveToFilesPlugin(rootViewController: rootViewController)
        let channel = FlutterMethodChannel(
            name: "com.imageeditor/save_to_files",
            binaryMessenger: registrar.messenger()
        )
        channel.setMethodCallHandler { call, result in
            instance.handle(call: call, result: result)
        }
    }

    private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "save":
            guard let args = call.arguments as? [String: Any],
                  let path = args["path"] as? String else {
                result(FlutterError(code: "BAD_ARGS",
                                    message: "Missing 'path' arg",
                                    details: nil))
                return
            }
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else {
                result(FlutterError(code: "FILE_NOT_FOUND",
                                    message: "No file at \(path)",
                                    details: nil))
                return
            }
            DispatchQueue.main.async {
                self.presentPicker(for: url, result: result)
            }
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func presentPicker(for url: URL, result: @escaping FlutterResult) {
        guard let presenter = rootViewController else {
            result(FlutterError(code: "NO_PRESENTER",
                                message: "No root view controller",
                                details: nil))
            return
        }
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        let delegate = PickerDelegate { picked in
            self.pendingResult = nil
            self.pendingDelegate = nil
            result(picked)
        }
        // Hold strong refs until the delegate fires — UIKit only holds
        // a weak ref to UIDocumentPickerDelegate, so without the
        // pending fields the delegate can be deallocated mid-pick.
        pendingDelegate = delegate
        pendingResult = result
        picker.delegate = delegate
        picker.modalPresentationStyle = .formSheet
        presenter.present(picker, animated: true)
    }
}

private final class PickerDelegate: NSObject, UIDocumentPickerDelegate {
    private let onResolved: (Bool) -> Void

    init(_ onResolved: @escaping (Bool) -> Void) {
        self.onResolved = onResolved
    }

    func documentPicker(_ controller: UIDocumentPickerViewController,
                        didPickDocumentsAt urls: [URL]) {
        onResolved(!urls.isEmpty)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        onResolved(false)
    }
}
