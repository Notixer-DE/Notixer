package de.noter.noter

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var media: MediaBridge? = null
    private var pending: MethodChannel.Result? = null
    private var pendingBytes: ByteArray? = null
    private var fileChannel: MethodChannel? = null
    private var sharedText: String? = null
    private fun sharedTextFrom(intent: Intent?): String? {
        if (intent?.action != Intent.ACTION_SEND || intent.type?.startsWith("text/") != true) return null
        return intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()?.take(1024 * 1024)
    }
    override fun onCreate(savedInstanceState: Bundle?) {
        sharedText = sharedTextFrom(intent)
        super.onCreate(savedInstanceState)
    }
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        sharedTextFrom(intent)?.let { text ->
            sharedText = text
            fileChannel?.invokeMethod("sharedText", text)
        }
    }
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        media = MediaBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "de.noter/files")
        fileChannel = channel
        channel.setMethodCallHandler { call, result ->
                if (call.method == "getSharedText") { result.success(sharedText); sharedText = null; return@setMethodCallHandler }
                if (call.method != "save") { result.notImplemented(); return@setMethodCallHandler }
                if (pending != null) { result.error("BUSY", "A save dialog is already open.", null); return@setMethodCallHandler }
                val bytes = call.argument<ByteArray>("bytes")
                if (bytes == null) { result.error("DATA", "No file data.", null); return@setMethodCallHandler }
                pending = result
                pendingBytes = bytes
                try {
                    val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = call.argument<String>("mime") ?: "application/octet-stream"
                        putExtra(Intent.EXTRA_TITLE, call.argument<String>("name") ?: "Note.pdf")
                    }
                    startActivityForResult(intent, 701)
                } catch (error: Exception) {
                    pending = null; pendingBytes = null
                    result.error("SAVE", error.message, null)
                }
            }
    }
    @Deprecated("Activity result bridge for Flutter")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (media?.onActivityResult(requestCode, resultCode, data) == true) return
        if (requestCode != 701) return
        val reply = pending ?: return
        val bytes = pendingBytes
        pending = null; pendingBytes = null
        if (resultCode != Activity.RESULT_OK || data?.data == null || bytes == null) {
            reply.success(false); return
        }
        val uri = data.data!!
        Thread {
            try {
                val stream = contentResolver.openOutputStream(uri, "wt")
                    ?: throw java.io.IOException("Could not open the file.")
                stream.use { it.write(bytes); it.flush() }
                runOnUiThread { reply.success(true) }
            } catch (error: Exception) {
                runOnUiThread { reply.error("SAVE", error.message, null) }
            }
        }.start()
    }
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        media?.onPermissionsResult(requestCode, grantResults)
    }
    override fun onStop() { media?.onStop(); super.onStop() }
    override fun onDestroy() { media?.dispose(); media = null; super.onDestroy() }

}
