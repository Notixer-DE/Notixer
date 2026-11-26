package de.noter.noter

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.widget.Toast
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException
import java.util.UUID

class MainActivity : FlutterActivity() {
    private var media: MediaBridge? = null
    private var fileChannel: MethodChannel? = null
    private var sharedText: String? = null
    private var shareReceiverReady = false
    private var exportReply: MethodChannel.Result? = null
    private var exportFile: File? = null
    private var pickingExportLocation = false

    private fun sharedTextFrom(intent: Intent?): String? {
        if (intent?.action != Intent.ACTION_SEND || intent.type?.startsWith("text/") != true) return null
        return intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()?.take(1024 * 1024)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        if (savedInstanceState == null || savedInstanceState.getBoolean("unreadShare")) {
            sharedText = sharedTextFrom(intent)
        }
        savedInstanceState?.getString("pendingExport")?.let { name ->
            val file = File(filesDir, name)
            exportFile = file
            pickingExportLocation = true
        }
        super.onCreate(savedInstanceState)
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putBoolean("unreadShare", sharedText != null)
        if (pickingExportLocation) outState.putString("pendingExport", exportFile?.name)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val text = sharedTextFrom(intent) ?: return
        val channel = fileChannel
        if (shareReceiverReady && channel != null) {
            sharedText = null
            channel.invokeMethod("sharedText", text)
        } else {
            sharedText = text
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        media = MediaBridge(this, messenger)
        val channel = MethodChannel(messenger, "de.noter/files")
        fileChannel = channel
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "getSharedText" -> {
                    shareReceiverReady = true
                    val text = sharedText
                    sharedText = null
                    result.success(text)
                }
                "save" -> {
                    val bytes = call.argument<ByteArray>("bytes")
                    when {
                        exportFile != null -> result.error("BUSY", "An export is already in progress.", null)
                        bytes == null -> result.error("DATA", "No file data.", null)
                        else -> stageExport(
                            channel, result, bytes,
                            call.argument<String>("mime") ?: "application/octet-stream",
                            call.argument<String>("name") ?: "Note.pdf",
                        )
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun stageExport(
        channel: MethodChannel,
        reply: MethodChannel.Result,
        bytes: ByteArray,
        mime: String,
        name: String,
    ) {
        val file = File(filesDir, "saf-export-${UUID.randomUUID()}")
        exportFile = file
        exportReply = reply
        Thread {
            val failure = runCatching {
                file.outputStream().use { stream ->
                    stream.write(bytes)
                    stream.fd.sync()
                }
            }.exceptionOrNull()
            runOnUiThread {
                if (fileChannel !== channel || exportFile != file || isFinishing || isDestroyed) {
                    file.delete()
                    if (exportFile == file) {
                        exportFile = null
                        exportReply = null
                    }
                    return@runOnUiThread
                }
                try {
                    if (failure != null) throw failure
                    val picker = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = mime
                        putExtra(Intent.EXTRA_TITLE, name)
                    }
                    pickingExportLocation = true
                    startActivityForResult(picker, EXPORT_REQUEST)
                } catch (error: Exception) {
                    pickingExportLocation = false
                    exportFile = null
                    exportReply = null
                    file.delete()
                    reply.error("SAVE", error.message, null)
                }
            }
        }.start()
    }

    @Deprecated("Activity result bridge for Flutter")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (media?.onActivityResult(requestCode, resultCode, data) == true) return
        if (requestCode != EXPORT_REQUEST) return
        val file = exportFile
        val reply = exportReply
        val channel = fileChannel
        pickingExportLocation = false
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            exportFile = null
            exportReply = null
            file?.delete()
            reply?.success(false)
            return
        }
        val context = applicationContext
        Thread {
            val failure = runCatching {
                // Open the staged file first so a missing payload cannot truncate the destination.
                (file ?: throw IOException("The export data is no longer available."))
                    .inputStream().use { input ->
                        val stream = context.contentResolver.openOutputStream(uri, "wt")
                            ?: throw IOException("Could not open the file.")
                        stream.use { input.copyTo(it) }
                    }
            }.exceptionOrNull()
            file?.delete()
            runOnUiThread {
                if (exportFile == file) {
                    exportFile = null
                    exportReply = null
                }
                if (isDestroyed || isFinishing || fileChannel !== channel) return@runOnUiThread
                if (reply != null) {
                    if (failure == null) reply.success(true)
                    else reply.error("SAVE", failure.message, null)
                } else {
                    val message = if (failure == null) "File saved."
                        else "Could not save the file: ${failure.message}"
                    Toast.makeText(context, message, Toast.LENGTH_LONG).show()
                }
            }
        }.start()
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        media?.onPermissionsResult(requestCode, grantResults)
    }

    override fun onStop() {
        media?.onStop()
        super.onStop()
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        media?.dispose()
        media = null
        fileChannel?.setMethodCallHandler(null)
        fileChannel = null
        shareReceiverReady = false
        exportReply = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onDestroy() {
        if (pickingExportLocation && isFinishing) exportFile?.delete()
        super.onDestroy()
    }

    private companion object {
        const val EXPORT_REQUEST = 701
    }
}
