package com.imageeditor.image_editor

import com.google.android.gms.common.GoogleApiAvailability
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val playServicesChannelName = "com.imageeditor/play_services"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Tiny method channel that surfaces the GoogleApiAvailability
        // result code (0 = SUCCESS) so the scanner UI can grey-out the
        // native strategy and explain why on devices without Play
        // Services. Keeping the channel here (rather than as a
        // dedicated plugin) avoids a pubspec dependency and matches
        // the read-only nature of the API.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            playServicesChannelName
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "checkAvailability" -> {
                    val code = GoogleApiAvailability.getInstance()
                        .isGooglePlayServicesAvailable(applicationContext)
                    result.success(code)
                }
                else -> result.notImplemented()
            }
        }
    }
}
