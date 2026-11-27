package __PACKAGE__

import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.WindowManager
import com.chaquo.python.Python
import com.chaquo.python.android.AndroidPlatform
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val executor = Executors.newSingleThreadExecutor()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        @Suppress("DEPRECATION")
        window.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            @Suppress("DEPRECATION")
            window.setDecorFitsSystemWindows(true)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "astra/python",
        ).setMethodCallHandler { call, result ->
            if (call.method != "run") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val code = call.argument<String>("code").orEmpty()
            val workspace = call.argument<String>("workspace")
                ?: cacheDir.absolutePath
            val timeoutMs = call.argument<Int>("timeoutMs") ?: 30000
            executor.execute {
                try {
                    if (!Python.isStarted()) {
                        Python.start(AndroidPlatform(applicationContext))
                    }
                    val module = Python.getInstance().getModule("astra_runner")
                    val raw = module.callAttr(
                        "run_code",
                        code,
                        workspace,
                        timeoutMs,
                    ).toString()
                    val json = JSONObject(raw)
                    val payload = hashMapOf<String, Any>(
                        "stdout" to json.optString("stdout", ""),
                        "stderr" to json.optString("stderr", ""),
                        "exitCode" to json.optInt("exitCode", 0),
                        "timedOut" to json.optBoolean("timedOut", false),
                    )
                    Handler(Looper.getMainLooper()).post {
                        result.success(payload)
                    }
                } catch (error: Throwable) {
                    Handler(Looper.getMainLooper()).post {
                        result.error(
                            "python_error",
                            error.message ?: error.toString(),
                            null,
                        )
                    }
                }
            }
        }
    }

    override fun onDestroy() {
        executor.shutdown()
        super.onDestroy()
    }
}
