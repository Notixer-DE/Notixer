package de.noter.noter

import android.Manifest
import android.app.Activity
import android.content.ClipData
import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaPlayer
import android.media.MediaRecorder
import android.os.Build
import android.provider.MediaStore
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File

/** Capture output always stays in the private cache until Dart imports it. */
class MediaBridge(private val activity: FlutterActivity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "de.noter/media")
    private val captureState = activity.getSharedPreferences("media_capture", 0)
    private var capturePermission: Pair<Boolean, MethodChannel.Result>? = null
    private var disposed = false
    private var captureReply: MethodChannel.Result? = null
    private var captureFile: File? = null
    private var permissionReply: MethodChannel.Result? = null
    private var recorder: MediaRecorder? = null
    private var recording: File? = null
    private var player: MediaPlayer? = null
    private var playerOwner: String? = null
    private var autoplay = false
    private var preparing: MethodChannel.Result? = null

    init {
        channel.setMethodCallHandler { call, result ->
            try {
                if (call.method in listOf("pause", "resume", "seek", "stop") && call.argument<String>("owner") != playerOwner) {
                    result.success(null); return@setMethodCallHandler
                }
                when (call.method) {
                    "pendingCaptures" -> result.success(activity.cacheDir.listFiles()?.filter {
                        (it.name.startsWith("capture-") || it.name.startsWith("voice-")) && it.length() > 0 && it != recording && it != captureFile
                    }?.map { it.absolutePath } ?: emptyList<String>())
                    "capture" -> capture(call.argument<Boolean>("video") == true, result)
                    "startRecording" -> {
                        if (recorder != null || recording != null || permissionReply != null) {
                            result.error("BUSY", "A recording is already open.", null)
                        } else if (activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                            permissionReply = result
                            activity.requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), 704)
                        } else startRecording(result)
                    }
                    "stopRecording" -> {
                        stopRecording()
                        val file = recording
                        recording = null
                        if (file == null || !file.exists() || file.length() == 0L) result.error("EMPTY", "No audio was recorded.", null)
                        else result.success(file.absolutePath)
                    }
                    "cancelRecording" -> { discardRecording(); result.success(null) }
                    "play" -> {
                        releasePlayer()
                        val path = call.argument<String>("path") ?: error("Missing audio path.")
                        val audio = MediaPlayer()
                        player = audio
                        playerOwner = call.argument<String>("owner")
                        preparing = result
                        autoplay = true
                        audio.setDataSource(path)
                        audio.setOnPreparedListener {
                            if (player === it) {
                                val reply = preparing
                                preparing = null
                                try {
                                    if (autoplay) it.start()
                                    reply?.success(it.duration)
                                } catch (error: Exception) {
                                    reply?.error("PLAY", error.message, null)
                                    releasePlayer()
                                }
                            }
                        }
                        audio.setOnErrorListener { failed, _, _ ->
                            if (player === failed) {
                                val reply = preparing
                                preparing = null
                                reply?.error("PLAY", "This audio format cannot be played on this device.", null)
                                releasePlayer()
                            }
                            true
                        }
                        audio.prepareAsync()
                    }
                    "pause" -> {
                        autoplay = false
                        if (preparing == null) player?.let { if (it.isPlaying) it.pause() }
                        result.success(null)
                    }
                    "resume" -> {
                        autoplay = true
                        if (preparing == null) player?.start()
                        result.success(null)
                    }
                    "seek" -> {
                        if (preparing == null) player?.seekTo(call.argument<Int>("position") ?: 0)
                        result.success(null)
                    }
                    "status" -> {
                        val ready = if (preparing == null) player else null
                        result.success(mapOf(
                            "owner" to playerOwner,
                            "position" to (ready?.currentPosition ?: 0),
                            "duration" to (ready?.duration ?: 0),
                            "playing" to (ready?.isPlaying ?: false),
                            "recording" to (recorder != null),
                        ))
                    }
                    "stop" -> { releasePlayer(); result.success(null) }
                    "openVideo" -> {
                        val file = File(call.argument<String>("path") ?: error("Missing video path."))
                        val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.media", file)
                        activity.startActivity(Intent(activity, MediaVideoActivity::class.java).setData(uri))
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            } catch (error: Exception) {
                if (call.method == "play") { preparing = null; releasePlayer() }
                result.error("MEDIA", error.message ?: "Media operation failed.", null)
            }
        }
    }

    private fun capture(video: Boolean, result: MethodChannel.Result) {
        if (captureReply != null || capturePermission != null) {
            result.error("BUSY", "The camera is already open.", null)
            return
        }
        if (activity.checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
            launchCapture(video, result)
            return
        }
        capturePermission = video to result
        try {
            activity.requestPermissions(arrayOf(Manifest.permission.CAMERA), CAMERA_PERMISSION_REQUEST)
        } catch (error: Exception) {
            capturePermission = null
            result.error("PERMISSION", error.message, null)
        }
    }

    private fun launchCapture(video: Boolean, result: MethodChannel.Result) {
        var output: File? = null
        try {
            val file = File.createTempFile("capture-", if (video) ".mp4" else ".jpg", activity.cacheDir)
            output = file
            val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.media", file)
            val intent = Intent(if (video) MediaStore.ACTION_VIDEO_CAPTURE else MediaStore.ACTION_IMAGE_CAPTURE).apply {
                putExtra(MediaStore.EXTRA_OUTPUT, uri)
                if (video) { putExtra(MediaStore.EXTRA_DURATION_LIMIT, 600); putExtra(MediaStore.EXTRA_SIZE_LIMIT, 128L * 1024 * 1024) }
                clipData = ClipData.newRawUri("Capture", uri)
                addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            captureReply = result
            captureFile = file
            captureState.edit().putString("pending", file.absolutePath).apply()
            activity.startActivityForResult(intent, 703)
        } catch (error: Exception) {
            captureReply = null; captureFile = null; output?.delete(); captureState.edit().remove("pending").apply()
            result.error("CAMERA", "No camera is available: ${error.message}", null)
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != 703) return false
        val reply = captureReply
        val file = captureFile ?: captureState.getString("pending", null)?.let { File(it) }
        captureReply = null; captureFile = null
        captureState.edit().remove("pending").apply()
        if (resultCode != Activity.RESULT_OK || file == null) {
            file?.delete(); reply?.success(null); return true
        }
        // Some camera apps return a content URI instead of honoring EXTRA_OUTPUT.
        Thread {
            try {
                if (file.length() == 0L && data?.data != null) {
                    activity.contentResolver.openInputStream(data.data!!)?.use { input ->
                        file.outputStream().use { output ->
                            val buffer = ByteArray(65536)
                            var total = 0L
                            while (true) {
                                val count = input.read(buffer)
                                if (count < 0) break
                                total += count
                                if (total > 128L * 1024 * 1024) error("Media exceeds 128 MB.")
                                output.write(buffer, 0, count)
                            }
                        }
                    }
                }
                if (file.length() == 0L) { file.delete(); activity.runOnUiThread { if (!disposed && !activity.isDestroyed) reply?.success(null) } }
                else activity.runOnUiThread {
                    if (disposed || activity.isDestroyed) return@runOnUiThread
                    if (reply != null) reply.success(file.absolutePath)
                    else channel.invokeMethod("captureRecovered", file.absolutePath)
                }
            } catch (error: Exception) {
                file.delete(); activity.runOnUiThread { if (!disposed && !activity.isDestroyed) reply?.error("CAPTURE", error.message, null) }
            }
        }.start()
        return true
    }

    fun onPermissionsResult(requestCode: Int, grantResults: IntArray): Boolean {
        if (requestCode == CAMERA_PERMISSION_REQUEST) {
            val pending = capturePermission
            capturePermission = null
            if (pending != null) {
                val (video, reply) = pending
                if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) {
                    launchCapture(video, reply)
                } else {
                    reply.error("PERMISSION", "Camera access was denied. Allow it in Android app permissions to take photos or record video.", null)
                }
            }
            return true
        }
        if (requestCode != 704) return false
        val reply = permissionReply
        permissionReply = null
        if (reply != null) {
            if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) {
                try { startRecording(reply) } catch (error: Exception) { reply.error("RECORD", error.message, null) }
            }
            else reply.error("PERMISSION", "Microphone access was denied. Allow it in Android app permissions to record audio.", null)
        }
        return true
    }

    @Suppress("DEPRECATION")
    private fun startRecording(reply: MethodChannel.Result) {
        val file = File.createTempFile("voice-", ".m4a", activity.cacheDir)
        val audio = if (Build.VERSION.SDK_INT >= 31) MediaRecorder(activity) else MediaRecorder()
        try {
            audio.setAudioSource(MediaRecorder.AudioSource.MIC)
            audio.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            audio.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            audio.setAudioSamplingRate(44100)
            audio.setAudioEncodingBitRate(96000)
            audio.setOutputFile(file.absolutePath)
            audio.setMaxDuration(600000)
            audio.setMaxFileSize(32L * 1024 * 1024)
            audio.setOnInfoListener { _, what, _ ->
                if (what == MediaRecorder.MEDIA_RECORDER_INFO_MAX_DURATION_REACHED || what == MediaRecorder.MEDIA_RECORDER_INFO_MAX_FILESIZE_REACHED) stopRecording()
            }
            audio.prepare(); audio.start()
            recording = file; recorder = audio
            reply.success(null)
        } catch (error: Exception) {
            audio.release(); file.delete()
            reply.error("RECORD", "Could not start recording: ${error.message}", null)
        }
    }

    private fun stopRecording() {
        val audio = recorder ?: return
        recorder = null
        try { audio.stop() } catch (_: Exception) { recording?.delete() }
        finally { audio.release() }
    }
    private fun discardRecording() { stopRecording(); recording?.delete(); recording = null }
    private fun releasePlayer() {
        preparing?.error("CANCELLED", "Playback was cancelled.", null)
        preparing = null
        autoplay = false
        player?.release(); player = null; playerOwner = null
    }
    fun onStop() { stopRecording(); releasePlayer() }
    fun dispose() {
        disposed = true
        capturePermission?.second?.error("CANCELLED", "Camera access was interrupted.", null)
        capturePermission = null
        stopRecording(); recording = null; releasePlayer()
        captureReply?.success(null); captureReply = null
        permissionReply?.error("CANCELLED", "Recording was cancelled.", null); permissionReply = null
        captureFile = null
        channel.setMethodCallHandler(null)
    }
    private companion object {
        const val CAMERA_PERMISSION_REQUEST = 705
    }
}
