package com.metamind.stria

import android.content.Context
import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Extracts the first audio track from a video file using Android's built-in
 * MediaExtractor + MediaCodec. No external libraries required.
 *
 * Output: 16-bit signed PCM, mono, WAV file in the app cache dir.
 * Maximum duration: [maxDurationMs] milliseconds (default 30 s).
 */
object VideoAudioExtractor {

    private const val DEFAULT_MAX_MS = 30_000L
    private const val TIMEOUT_US = 10_000L // dequeue timeout

    /**
     * @param context  Android context (used for cache dir).
     * @param videoPath  Absolute path to the video file.
     * @param maxDurationMs  Hard cap on extracted audio length.
     * @return  Absolute path to the generated WAV file, or null on failure.
     */
    fun extractToWav(
        context: Context,
        videoPath: String,
        maxDurationMs: Long = DEFAULT_MAX_MS,
    ): String? {
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(videoPath)

            // ── 1. Find the first audio track ────────────────────────────────
            var audioTrackIndex = -1
            var audioFormat: MediaFormat? = null
            for (i in 0 until extractor.trackCount) {
                val fmt = extractor.getTrackFormat(i)
                val mime = fmt.getString(MediaFormat.KEY_MIME) ?: continue
                if (mime.startsWith("audio/")) {
                    audioTrackIndex = i
                    audioFormat = fmt
                    break
                }
            }
            if (audioTrackIndex == -1 || audioFormat == null) return null

            extractor.selectTrack(audioTrackIndex)

            val mime = audioFormat.getString(MediaFormat.KEY_MIME)!!
            val sourceSampleRate = audioFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            val sourceChannels = audioFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)

            // ── 2. Decode with MediaCodec ─────────────────────────────────────
            val codec = MediaCodec.createDecoderByType(mime)
            codec.configure(audioFormat, null, null, 0)
            codec.start()

            val bufferInfo = MediaCodec.BufferInfo()
            val rawPcm = ByteArrayOutputStream()
            val maxUs = maxDurationMs * 1_000L
            var inputDone = false
            var outputDone = false
            var outputSampleRate = sourceSampleRate
            var outputChannels = sourceChannels
            var outputEncoding = AudioFormat.ENCODING_PCM_16BIT

            while (!outputDone) {
                // Feed input
                if (!inputDone) {
                    val inIdx = codec.dequeueInputBuffer(TIMEOUT_US)
                    if (inIdx >= 0) {
                        val inBuf: ByteBuffer = codec.getInputBuffer(inIdx)!!
                        val sampleSize = extractor.readSampleData(inBuf, 0)
                        val pts = extractor.sampleTime
                        if (sampleSize < 0 || pts > maxUs) {
                            codec.queueInputBuffer(
                                inIdx, 0, 0, 0,
                                MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                            )
                            inputDone = true
                        } else {
                            codec.queueInputBuffer(inIdx, 0, sampleSize, pts, 0)
                            extractor.advance()
                        }
                    }
                }

                // Drain output
                val outIdx = codec.dequeueOutputBuffer(bufferInfo, TIMEOUT_US)
                when {
                    outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        val fmt = codec.outputFormat
                        outputSampleRate = fmt.getInteger(
                            MediaFormat.KEY_SAMPLE_RATE, sourceSampleRate,
                        )
                        outputChannels = fmt.getInteger(
                            MediaFormat.KEY_CHANNEL_COUNT, sourceChannels,
                        )
                        outputEncoding = fmt.getInteger(
                            MediaFormat.KEY_PCM_ENCODING,
                            AudioFormat.ENCODING_PCM_16BIT,
                        )
                    }
                    outIdx >= 0 -> {
                        val outBuf: ByteBuffer = codec.getOutputBuffer(outIdx)!!
                        if (bufferInfo.size > 0) {
                            val chunk = ByteArray(bufferInfo.size)
                            outBuf.get(chunk)
                            rawPcm.write(chunk)
                        }
                        codec.releaseOutputBuffer(outIdx, false)
                        if (bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                            outputDone = true
                        }
                    }
                }
            }

            codec.stop()
            codec.release()
            extractor.release()

            // ── 3. Post-process: float→int16, then multi-ch→mono ─────────────
            var pcm: ByteArray = rawPcm.toByteArray()

            if (outputEncoding == AudioFormat.ENCODING_PCM_FLOAT) {
                pcm = floatToInt16(pcm)
            }

            if (outputChannels > 1) {
                pcm = downmixToMono(pcm, outputChannels)
            }

            // ── 4. Write WAV ──────────────────────────────────────────────────
            val outFile = File(
                context.cacheDir,
                "video_extract_${System.currentTimeMillis()}.wav",
            )
            writeWav(outFile, pcm, channels = 1, sampleRate = outputSampleRate)
            return outFile.absolutePath

        } catch (e: Exception) {
            extractor.release()
            return null
        }
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    /** Convert 32-bit float PCM (little-endian) to 16-bit signed PCM. */
    private fun floatToInt16(floatPcm: ByteArray): ByteArray {
        val floats = ByteBuffer.wrap(floatPcm)
            .order(ByteOrder.LITTLE_ENDIAN)
            .asFloatBuffer()
        val count = floats.limit()
        val result = ByteArray(count * 2)
        val out = ByteBuffer.wrap(result).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
        for (i in 0 until count) {
            val f = floats.get().coerceIn(-1f, 1f)
            out.put((f * Short.MAX_VALUE).toInt().toShort())
        }
        return result
    }

    /** Average all channels to produce mono 16-bit PCM. */
    private fun downmixToMono(pcm: ByteArray, channels: Int): ByteArray {
        val totalSamples = pcm.size / 2           // each sample = 2 bytes (int16)
        val monoSamples = totalSamples / channels
        val result = ByteArray(monoSamples * 2)
        val inBuf = ByteBuffer.wrap(pcm).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
        val outBuf = ByteBuffer.wrap(result).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
        for (i in 0 until monoSamples) {
            var sum = 0
            for (c in 0 until channels) sum += inBuf.get().toInt()
            outBuf.put((sum / channels).toShort())
        }
        return result
    }

    /** Write a standard 16-bit PCM WAV file. */
    private fun writeWav(file: File, pcm: ByteArray, channels: Int, sampleRate: Int) {
        val dataSize = pcm.size
        FileOutputStream(file).use { out ->
            fun wi(v: Int) {
                out.write(v and 0xFF)
                out.write((v shr 8) and 0xFF)
                out.write((v shr 16) and 0xFF)
                out.write((v shr 24) and 0xFF)
            }
            fun ws(v: Int) {
                out.write(v and 0xFF)
                out.write((v shr 8) and 0xFF)
            }
            out.write("RIFF".toByteArray())
            wi(36 + dataSize)          // total file size − 8
            out.write("WAVE".toByteArray())
            out.write("fmt ".toByteArray())
            wi(16)                     // fmt chunk size
            ws(1)                      // PCM format
            ws(channels)
            wi(sampleRate)
            wi(sampleRate * channels * 2)  // byte rate
            ws(channels * 2)           // block align
            ws(16)                     // bits per sample
            out.write("data".toByteArray())
            wi(dataSize)
            out.write(pcm)
        }
    }
}
