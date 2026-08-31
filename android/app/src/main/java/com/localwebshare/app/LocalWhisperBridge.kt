package com.localwebshare.app

import android.content.Context
import dev.ffmpegkit.whisper.Whisper
import dev.ffmpegkit.whisper.WhisperConfig
import kotlinx.coroutines.*

object LocalWhisperBridge {
    interface Callback {
        fun onProgress(message: String)
        fun onSuccess(tsv: String)
        fun onError(message: String)
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    @JvmStatic
    fun transcribe(context: Context, audioPath: String, callback: Callback) {
        callback.onProgress("Loading local transcription model…")
        scope.launch {
            try {
                val model = Whisper.loadModelFromAsset(context.applicationContext, "models/ggml-base.bin")
                try {
                    withContext(Dispatchers.Main) { callback.onProgress("Creating captions…") }
                    val result = Whisper.transcribe(model, audioPath, WhisperConfig())
                    val tsv = buildString {
                        result.segments.forEach { segment ->
                            val clean = segment.text.replace('\t', ' ').replace('\n', ' ').replace('\r', ' ').trim()
                            if (clean.isNotEmpty()) append(segment.startMs).append('\t').append(segment.endMs).append('\t').append(clean).append('\n')
                        }
                    }
                    withContext(Dispatchers.Main) { callback.onSuccess(tsv) }
                } finally {
                    Whisper.releaseModel(model)
                }
            } catch (t: Throwable) {
                withContext(Dispatchers.Main) { callback.onError(t.message ?: "Local Whisper transcription failed") }
            }
        }
    }
}
