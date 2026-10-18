package run.serv.modus

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.Build
import android.os.Bundle
import android.os.PersistableBundle
import android.view.WindowManager
import androidx.core.view.WindowCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        // Notes are decrypted on screen: keep them out of screenshots,
        // screen recordings, casting and the recent-apps thumbnail. Set
        // before Flutter draws its first frame.
        window.setFlags(
            WindowManager.LayoutParams.FLAG_SECURE,
            WindowManager.LayoutParams.FLAG_SECURE,
        )
        // Edge to edge on every version, as Android 15 imposes on apps
        // targeting API 35: Flutter pads for the system bars from their
        // insets. Flutter resets the flags this sets below Android 11.
        WindowCompat.setDecorFitsSystemWindows(window, false)
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "run.serv.modus/clipboard")
            .setMethodCallHandler { call, result ->
                val text = call.argument<String>("text")
                if (call.method != "copySecret" || text == null) {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                // Marked sensitive, the system clipboard preview shows dots
                // and keyboards leave it out of their clipboard history.
                val clip = ClipData.newPlainText("", text)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    clip.description.extras = PersistableBundle().apply {
                        // ClipDescription.EXTRA_IS_SENSITIVE from Android 13,
                        // read by keyboards on older versions too.
                        putBoolean("android.content.extra.IS_SENSITIVE", true)
                    }
                }
                val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                clipboard.setPrimaryClip(clip)
                result.success(null)
            }
    }
}
