package com.metamind.stria

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import androidx.documentfile.provider.DocumentFile
import com.metamind.stria.AudioEnginePlugin
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.nio.charset.StandardCharsets

class MainActivity : FlutterActivity(), AudioManager.OnAudioFocusChangeListener {
	private val requestPickProjectFolder = 60241
	private var pendingPickFolderResult: MethodChannel.Result? = null
	private lateinit var projectStorageChannel: MethodChannel

	// Kept as a field so the focus handler can reach it.
	private lateinit var audioPlugin: AudioEnginePlugin

	private lateinit var audioManager: AudioManager
	private var focusRequest: AudioFocusRequest? = null   // API 26+

	override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
		super.configureFlutterEngine(flutterEngine)
		audioPlugin = AudioEnginePlugin()
		flutterEngine.plugins.add(audioPlugin)

		// Video audio extraction channel (uses Android MediaExtractor/MediaCodec)
		MethodChannel(
			flutterEngine.dartExecutor.binaryMessenger,
			"video_audio_extractor",
		).setMethodCallHandler { call, result ->
			when (call.method) {
				"extractVideoAudio" -> {
					val path = call.argument<String>("path")
					if (path.isNullOrBlank()) {
						result.error("bad_args", "Missing path", null)
						return@setMethodCallHandler
					}
					Thread {
						val wavPath = VideoAudioExtractor.extractToWav(this, path)
						runOnUiThread { result.success(wavPath) }
					}.start()
				}
				else -> result.notImplemented()
			}
		}

		projectStorageChannel = MethodChannel(
			flutterEngine.dartExecutor.binaryMessenger,
			"project_storage"
		)
		projectStorageChannel.setMethodCallHandler { call, result ->
			when (call.method) {
				"pickProjectFolder" -> {
					if (pendingPickFolderResult != null) {
						result.error("busy", "Folder picker already active", null)
						return@setMethodCallHandler
					}
					pendingPickFolderResult = result
					val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
						addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
						addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
						addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
						addFlags(Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
					}
					startActivityForResult(intent, requestPickProjectFolder)
				}
				"listProjectFiles" -> {
					val treeUriRaw = call.argument<String>("treeUri")
					if (treeUriRaw.isNullOrBlank()) {
						result.success(emptyList<Map<String, String>>())
						return@setMethodCallHandler
					}

					try {
						val root = DocumentFile.fromTreeUri(this, Uri.parse(treeUriRaw))
						if (root == null || !root.isDirectory) {
							result.success(emptyList<Map<String, String>>())
							return@setMethodCallHandler
						}

						val out = ArrayList<Map<String, String>>()
						for (child in root.listFiles()) {
							if (!child.isDirectory) continue
							val projectJson = findChildByName(child, "project.json")
							val legacyJson = findChildByName(child, "song.json")
							val selected = projectJson ?: legacyJson ?: continue
							out.add(
								mapOf(
									"folderName" to (child.name ?: ""),
									"uri" to selected.uri.toString()
								)
							)
						}
						result.success(out)
					} catch (e: Exception) {
						result.error("list_failed", e.message, null)
					}
				}
				"readTextFile" -> {
					val uriRaw = call.argument<String>("uri")
					if (uriRaw.isNullOrBlank()) {
						result.error("bad_args", "Missing uri", null)
						return@setMethodCallHandler
					}
					try {
						val text = contentResolver.openInputStream(Uri.parse(uriRaw)).use { input ->
							if (input == null) return@use null
							String(input.readBytes(), StandardCharsets.UTF_8)
						}
						result.success(text)
					} catch (e: Exception) {
						result.error("read_failed", e.message, null)
					}
				}
				"writeProjectFile" -> {
					val treeUriRaw = call.argument<String>("treeUri")
					val folderNameRaw = call.argument<String>("folderName")
					val text = call.argument<String>("text")
					if (treeUriRaw.isNullOrBlank() || folderNameRaw.isNullOrBlank() || text == null) {
						result.error("bad_args", "Missing treeUri/folderName/text", null)
						return@setMethodCallHandler
					}

					try {
						val root = DocumentFile.fromTreeUri(this, Uri.parse(treeUriRaw))
						if (root == null || !root.isDirectory || !root.canWrite()) {
							result.error("write_failed", "Project root is not writable", null)
							return@setMethodCallHandler
						}

						val folderName = folderNameRaw.trim()
						if (folderName.isEmpty()) {
							result.error("bad_args", "Invalid folder name", null)
							return@setMethodCallHandler
						}

						var projectFolder = findDirectoryByName(root, folderName)
						if (projectFolder == null) {
							projectFolder = root.createDirectory(folderName)
						}
						if (projectFolder == null || !projectFolder.isDirectory || !projectFolder.canWrite()) {
							result.error("write_failed", "Unable to create/access project folder", null)
							return@setMethodCallHandler
						}

						var projectFile = findChildByName(projectFolder, "project.json")
						if (projectFile == null) {
							projectFile = projectFolder.createFile("application/json", "project.json")
						}
						if (projectFile == null || !projectFile.isFile) {
							result.error("write_failed", "Unable to create project.json", null)
							return@setMethodCallHandler
						}

						contentResolver.openOutputStream(projectFile.uri, "wt")?.use { output ->
							output.write(text.toByteArray(StandardCharsets.UTF_8))
							output.flush()
						} ?: run {
							result.error("write_failed", "Unable to open project.json for write", null)
							return@setMethodCallHandler
						}

						result.success(true)
					} catch (e: Exception) {
						result.error("write_failed", e.message, null)
					}
				}
				"writeProjectBinaryFile" -> {
					val treeUriRaw = call.argument<String>("treeUri")
					val folderNameRaw = call.argument<String>("folderName")
					val fileNameRaw = call.argument<String>("fileName")
					val bytes = call.argument<ByteArray>("bytes")
					if (treeUriRaw.isNullOrBlank() || folderNameRaw.isNullOrBlank() || fileNameRaw.isNullOrBlank() || bytes == null) {
						result.error("bad_args", "Missing treeUri/folderName/fileName/bytes", null)
						return@setMethodCallHandler
					}

					try {
						val root = DocumentFile.fromTreeUri(this, Uri.parse(treeUriRaw))
						if (root == null || !root.isDirectory || !root.canWrite()) {
							result.error("write_failed", "Project root is not writable", null)
							return@setMethodCallHandler
						}

						val folderName = folderNameRaw.trim()
						if (folderName.isEmpty()) {
							result.error("bad_args", "Invalid folder name", null)
							return@setMethodCallHandler
						}

						var projectFolder = findDirectoryByName(root, folderName)
						if (projectFolder == null) {
							projectFolder = root.createDirectory(folderName)
						}
						if (projectFolder == null || !projectFolder.isDirectory || !projectFolder.canWrite()) {
							result.error("write_failed", "Unable to create/access project folder", null)
							return@setMethodCallHandler
						}

						val fileName = fileNameRaw.trim()
						if (fileName.isEmpty()) {
							result.error("bad_args", "Invalid file name", null)
							return@setMethodCallHandler
						}

						var outFile = findChildByName(projectFolder, fileName)
						if (outFile == null) {
							outFile = projectFolder.createFile("audio/wav", fileName)
						}
						if (outFile == null || !outFile.isFile) {
							result.error("write_failed", "Unable to create output file", null)
							return@setMethodCallHandler
						}

						contentResolver.openOutputStream(outFile.uri, "wt")?.use { output ->
							output.write(bytes)
							output.flush()
						} ?: run {
							result.error("write_failed", "Unable to open output file for write", null)
							return@setMethodCallHandler
						}

						result.success(outFile.uri.toString())
					} catch (e: Exception) {
						result.error("write_failed", e.message, null)
					}
				}
				"readProjectBinaryFile" -> {
					val treeUriRaw = call.argument<String>("treeUri")
					val folderNameRaw = call.argument<String>("folderName")
					val fileNameRaw = call.argument<String>("fileName")
					if (treeUriRaw.isNullOrBlank() || folderNameRaw.isNullOrBlank() || fileNameRaw.isNullOrBlank()) {
						result.error("bad_args", "Missing treeUri/folderName/fileName", null)
						return@setMethodCallHandler
					}
					try {
						val root = DocumentFile.fromTreeUri(this, Uri.parse(treeUriRaw))
						if (root == null || !root.isDirectory) {
							result.success(null)
							return@setMethodCallHandler
						}
						val folder = findDirectoryByName(root, folderNameRaw.trim())
						if (folder == null) {
							result.success(null)
							return@setMethodCallHandler
						}
						val file = findChildByName(folder, fileNameRaw.trim())
						if (file == null || !file.isFile) {
							result.success(null)
							return@setMethodCallHandler
						}
						val bytes = contentResolver.openInputStream(file.uri)?.use { it.readBytes() }
						result.success(bytes)
					} catch (e: Exception) {
						result.error("read_failed", e.message, null)
					}
				}
				else -> result.notImplemented()
			}
		}
	}

	override fun onResume() {
		super.onResume()
		audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
		requestAudioFocus()
		// Always restart the Oboe stream when returning to the app (covers the
		// case where AUDIOFOCUS_LOSS paused the stream during a phone call but
		// AUDIOFOCUS_GAIN never fired because we re-registered the listener).
		audioPlugin.resumeStream()
	}

	override fun onPause() {
		super.onPause()
		// Don't stop the stream here — let audio focus callbacks handle it so
		// that screen-lock / brief app-switches don't silence playback.
		// Focus is abandoned in onDestroy() when we truly stop.
	}

	private fun requestAudioFocus() {
		if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
			val attrs = AudioAttributes.Builder()
				.setUsage(AudioAttributes.USAGE_MEDIA)
				.setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
				.build()
			focusRequest = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
				.setAudioAttributes(attrs)
				.setAcceptsDelayedFocusGain(true)
				.setOnAudioFocusChangeListener(this)
				.build()
			audioManager.requestAudioFocus(focusRequest!!)
		} else {
			@Suppress("DEPRECATION")
			audioManager.requestAudioFocus(this, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN)
		}
	}

	private fun abandonAudioFocus() {
		if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
			focusRequest?.let { audioManager.abandonAudioFocusRequest(it) }
		} else {
			@Suppress("DEPRECATION")
			audioManager.abandonAudioFocus(this)
		}
	}

	override fun onAudioFocusChange(focusChange: Int) {
		when (focusChange) {
			AudioManager.AUDIOFOCUS_LOSS,
			AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> audioPlugin.pauseStream()
			AudioManager.AUDIOFOCUS_GAIN           -> audioPlugin.resumeStream()
			// AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK: notifications etc. — let them through, don't pause
		}
	}

	override fun onDestroy() {
		super.onDestroy()
		abandonAudioFocus()
	}

	override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
		super.onActivityResult(requestCode, resultCode, data)
		if (requestCode != requestPickProjectFolder) return

		val pending = pendingPickFolderResult
		pendingPickFolderResult = null
		if (pending == null) return

		if (resultCode != Activity.RESULT_OK) {
			pending.success(null)
			return
		}

		val uri = data?.data
		if (uri == null) {
			pending.success(null)
			return
		}

		val flags = data.flags
		val persistFlags = flags and
			(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
		try {
			contentResolver.takePersistableUriPermission(uri, persistFlags)
		} catch (_: SecurityException) {
			// Some providers may not allow persistable grants; still return URI.
		}

		pending.success(uri.toString())
	}

	private fun findChildByName(dir: DocumentFile, name: String): DocumentFile? {
		for (child in dir.listFiles()) {
			if (!child.isFile) continue
			if (child.name.equals(name, ignoreCase = true)) {
				return child
			}
		}
		return null
	}

	private fun findDirectoryByName(dir: DocumentFile, name: String): DocumentFile? {
		for (child in dir.listFiles()) {
			if (!child.isDirectory) continue
			if (child.name.equals(name, ignoreCase = true)) {
				return child
			}
		}
		return null
	}
}
