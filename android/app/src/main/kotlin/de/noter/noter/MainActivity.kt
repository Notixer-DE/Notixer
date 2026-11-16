package de.noter.noter

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var pending: MethodChannel.Result? = null
    private var pendingBytes: ByteArray? = null
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "de.noter/files")
            .setMethodCallHandler { call, result ->
                if (call.method != "save") { result.notImplemented(); return@setMethodCallHandler }
                if (pending != null) { result.error("BUSY", "Ein Speicherdialog ist bereits offen.", null); return@setMethodCallHandler }
                val bytes = call.argument<ByteArray>("bytes")
                if (bytes == null) { result.error("DATA", "Keine Dateidaten.", null); return@setMethodCallHandler }
                pending = result
                pendingBytes = bytes
                try {
                    val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = call.argument<String>("mime") ?: "application/octet-stream"
                        putExtra(Intent.EXTRA_TITLE, call.argument<String>("name") ?: "Notiz.pdf")
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
                    ?: throw java.io.IOException("Datei konnte nicht geöffnet werden.")
                stream.use { it.write(bytes); it.flush() }
                runOnUiThread { reply.success(true) }
            } catch (error: Exception) {
                runOnUiThread { reply.error("SAVE", error.message, null) }
            }
        }.start()
    }
}
