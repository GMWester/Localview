package io.localview.localview

import android.database.Cursor
import android.database.MatrixCursor
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import android.provider.DocumentsContract.Root
import android.provider.DocumentsProvider
import android.webkit.MimeTypeMap
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.util.concurrent.ConcurrentHashMap

/**
 * Shows connected devices' storage as drives in the Android Files app.
 * Talks to the app's loopback WebDAV bridge (which tunnels over the encrypted session).
 * Document ids are "<driveId>|<virtual path>".
 */
class DriveProvider : DocumentsProvider() {
    data class Drive(val name: String, val url: String)

    companion object {
        val drives = ConcurrentHashMap<String, Drive>()
        private val ROOT_COLS = arrayOf(Root.COLUMN_ROOT_ID, Root.COLUMN_DOCUMENT_ID, Root.COLUMN_TITLE,
            Root.COLUMN_SUMMARY, Root.COLUMN_FLAGS, Root.COLUMN_ICON)
        private val DOC_COLS = arrayOf(Document.COLUMN_DOCUMENT_ID, Document.COLUMN_DISPLAY_NAME, Document.COLUMN_MIME_TYPE,
            Document.COLUMN_SIZE, Document.COLUMN_LAST_MODIFIED, Document.COLUMN_FLAGS)
    }

    override fun onCreate(): Boolean = true

    private fun split(docId: String): Pair<Drive, String> {
        val i = docId.indexOf('|')
        val d = drives[docId.substring(0, i)] ?: throw java.io.FileNotFoundException("drive disconnected")
        return Pair(d, docId.substring(i + 1))
    }

    private fun url(d: Drive, path: String, query: String = ""): URL {
        val enc = path.split('/').filter { it.isNotEmpty() }
            .joinToString("/") { URLEncoder.encode(it, "UTF-8").replace("+", "%20") }
        return URL(d.url + enc + query)
    }

    private fun http(u: URL, method: String = "GET", body: File? = null): HttpURLConnection {
        val c = u.openConnection() as HttpURLConnection
        c.requestMethod = method
        c.connectTimeout = 10000
        c.readTimeout = 120000
        if (body != null) {
            c.doOutput = true
            c.setFixedLengthStreamingMode(body.length())
            c.outputStream.use { o -> body.inputStream().use { it.copyTo(o) } }
        } else if (method == "POST" || method == "PUT") {
            c.doOutput = true
            c.setFixedLengthStreamingMode(0)
            c.outputStream.close()
        }
        if (c.responseCode >= 400) throw java.io.FileNotFoundException("HTTP ${c.responseCode}")
        return c
    }

    private fun json(u: URL): String = http(u).inputStream.bufferedReader().use { it.readText() }

    private fun mime(name: String, dir: Boolean): String {
        if (dir) return Document.MIME_TYPE_DIR
        val ext = name.substringAfterLast('.', "").lowercase()
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: "application/octet-stream"
    }

    private fun addRow(c: MatrixCursor, docId: String, e: JSONObject, nameOverride: String? = null) {
        val dir = e.getBoolean("d")
        val name = nameOverride ?: e.getString("n")
        var flags = Document.FLAG_SUPPORTS_DELETE or Document.FLAG_SUPPORTS_RENAME
        flags = if (dir) flags or Document.FLAG_DIR_SUPPORTS_CREATE else flags or Document.FLAG_SUPPORTS_WRITE
        c.newRow().add(Document.COLUMN_DOCUMENT_ID, docId).add(Document.COLUMN_DISPLAY_NAME, name)
            .add(Document.COLUMN_MIME_TYPE, mime(name, dir)).add(Document.COLUMN_SIZE, e.getLong("s"))
            .add(Document.COLUMN_LAST_MODIFIED, e.getLong("m")).add(Document.COLUMN_FLAGS, flags)
    }

    override fun queryRoots(projection: Array<out String>?): Cursor {
        val c = MatrixCursor(projection ?: ROOT_COLS)
        for ((id, d) in drives) {
            c.newRow().add(Root.COLUMN_ROOT_ID, id).add(Root.COLUMN_DOCUMENT_ID, "$id|/").add(Root.COLUMN_TITLE, d.name)
                .add(Root.COLUMN_SUMMARY, "Localview").add(Root.COLUMN_FLAGS, Root.FLAG_SUPPORTS_CREATE or Root.FLAG_SUPPORTS_IS_CHILD)
                .add(Root.COLUMN_ICON, R.mipmap.ic_launcher)
        }
        c.setNotificationUri(context!!.contentResolver, DocumentsContract.buildRootsUri("${context!!.packageName}.documents"))
        return c
    }

    override fun queryDocument(documentId: String, projection: Array<out String>?): Cursor {
        val c = MatrixCursor(projection ?: DOC_COLS)
        val (d, p) = split(documentId)
        val e = JSONObject(json(url(d, p, "?lv=stat")))
        addRow(c, documentId, e, if (p == "/") d.name else null)
        return c
    }

    override fun queryChildDocuments(parentDocumentId: String, projection: Array<out String>?, sortOrder: String?): Cursor {
        val c = MatrixCursor(projection ?: DOC_COLS)
        val (d, p) = split(parentDocumentId)
        val arr = JSONArray(json(url(d, p, "?lv=list")))
        val prefix = parentDocumentId.substringBefore('|')
        for (i in 0 until arr.length()) {
            val e = arr.getJSONObject(i)
            val child = if (p == "/") "/${e.getString("n")}" else "$p/${e.getString("n")}"
            addRow(c, "$prefix|$child", e)
        }
        return c
    }

    override fun isChildDocument(parentDocumentId: String, documentId: String): Boolean {
        val parent = parentDocumentId.trimEnd('/')
        return documentId.startsWith("$parent/") || (parentDocumentId.endsWith("|/") && documentId.startsWith(parentDocumentId))
    }

    override fun openDocument(documentId: String, mode: String, signal: CancellationSignal?): ParcelFileDescriptor {
        val (d, p) = split(documentId)
        val tmp = File.createTempFile("lv", ".tmp", context!!.cacheDir)
        val writing = mode.contains('w')
        if (!mode.contains('t') || !writing) {
            try {
                http(url(d, p)).inputStream.use { i -> FileOutputStream(tmp).use { i.copyTo(it) } }
            } catch (e: Exception) {
                if (!writing) throw e
            }
        }
        if (!writing) {
            val pfd = ParcelFileDescriptor.open(tmp, ParcelFileDescriptor.MODE_READ_ONLY)
            tmp.delete()
            return pfd
        }
        return ParcelFileDescriptor.open(tmp, ParcelFileDescriptor.parseMode(mode), Handler(Looper.getMainLooper())) {
            Thread {
                try { http(url(d, p), "PUT", tmp).inputStream.close() } catch (_: Exception) {}
                tmp.delete()
            }.start()
        }
    }

    override fun createDocument(parentDocumentId: String, mimeType: String, displayName: String): String {
        val (d, p) = split(parentDocumentId)
        val child = if (p == "/") "/$displayName" else "$p/$displayName"
        if (mimeType == Document.MIME_TYPE_DIR) http(url(d, child, "?lv=mkdir"), "POST").inputStream.close()
        else http(url(d, child), "PUT").inputStream.close()
        return "${parentDocumentId.substringBefore('|')}|$child"
    }

    override fun deleteDocument(documentId: String) {
        val (d, p) = split(documentId)
        http(url(d, p), "DELETE").inputStream.close()
    }

    override fun renameDocument(documentId: String, displayName: String): String {
        val (d, p) = split(documentId)
        val target = p.substringBeforeLast('/') + "/" + displayName
        http(url(d, p, "?lv=move&to=" + URLEncoder.encode(target, "UTF-8")), "POST").inputStream.close()
        return "${documentId.substringBefore('|')}|$target"
    }
}
