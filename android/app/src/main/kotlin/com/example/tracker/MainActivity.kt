package com.example.tracker

import android.app.Activity
import android.content.Intent
import android.net.Uri
import androidx.documentfile.provider.DocumentFile
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.nio.charset.StandardCharsets

class MainActivity : FlutterActivity() {
	private val requestPickProjectFolder = 60241
	private var pendingPickFolderResult: MethodChannel.Result? = null
	private lateinit var projectStorageChannel: MethodChannel

	override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
		super.configureFlutterEngine(flutterEngine)
		flutterEngine.plugins.add(AudioEnginePlugin())

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
				else -> result.notImplemented()
			}
		}
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
