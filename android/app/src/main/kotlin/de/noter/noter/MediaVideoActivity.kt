package de.noter.noter

import android.app.Activity
import android.os.Bundle
import android.widget.MediaController
import android.widget.VideoView
import android.widget.Toast

/** A system-backed player keeps local video playback offline and in the app. */
class MediaVideoActivity : Activity() {
    private lateinit var video: VideoView
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.decorView.setBackgroundColor(android.graphics.Color.BLACK)
        video = VideoView(this)
        setContentView(video)
        val controls = MediaController(this)
        controls.setAnchorView(video)
        video.setMediaController(controls)
        video.setOnErrorListener { _, _, _ ->
            Toast.makeText(this, "This video cannot be played on this device.", Toast.LENGTH_LONG).show()
            finish(); true
        }
        video.setVideoURI(intent.data)
        video.setOnPreparedListener { video.seekTo(savedInstanceState?.getInt("position") ?: 0); video.start() }
    }
    override fun onPause() { video.pause(); super.onPause() }
    override fun onSaveInstanceState(outState: Bundle) { outState.putInt("position", video.currentPosition); super.onSaveInstanceState(outState) }
    override fun onDestroy() { video.stopPlayback(); super.onDestroy() }
}
