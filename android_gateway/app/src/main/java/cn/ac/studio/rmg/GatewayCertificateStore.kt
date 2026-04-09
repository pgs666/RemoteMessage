package cn.ac.studio.rmg

import android.content.Context
import android.net.Uri
import java.io.File
import java.io.InputStream
import java.security.cert.CertificateFactory

object GatewayCertificateStore {
    private const val FILE_NAME = "trusted_server_cert.cer"

    fun certFile(context: Context): File = File(context.filesDir, FILE_NAME)

    fun hasCertificate(context: Context): Boolean = certFile(context).exists()

    fun importFromUri(context: Context, uri: Uri) {
        val bytes = context.contentResolver.openInputStream(uri).use { input ->
            requireNotNull(input) { "cannot open certificate stream" }
            input.readBytes()
        }
        require(bytes.isNotEmpty()) { "empty certificate file" }
        CertificateFactory.getInstance("X.509").generateCertificate(bytes.inputStream())
        certFile(context).writeBytes(bytes)
    }

    fun openInputStream(context: Context): InputStream? {
        val file = certFile(context)
        if (!file.exists()) return null
        return file.inputStream()
    }
}
