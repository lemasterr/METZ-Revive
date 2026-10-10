package com.metzrevive.display

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.math.BigInteger
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.Principal
import java.security.PrivateKey
import java.net.Socket
import java.security.MessageDigest
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import java.util.Date
import javax.net.ssl.X509ExtendedKeyManager
import javax.net.ssl.SSLEngine
import javax.net.ssl.SSLContext
import javax.net.ssl.X509TrustManager
import javax.security.auth.x500.X500Principal

object StreamIdentity {
    // Keep v1 in Keystore for a source/APK rollback; never overwrite or delete it.
    private const val ALIAS = "metz-display-tls-v2"
    private fun store(): KeyStore {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        if (!store.containsAlias(ALIAS)) {
            KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_RSA, "AndroidKeyStore").apply {
                initialize(KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY or KeyProperties.PURPOSE_DECRYPT)
                    // Conscrypt hashes TLS transcripts itself and uses raw RSA crypto upcalls.
                    .setKeySize(2048).setDigests(KeyProperties.DIGEST_NONE, KeyProperties.DIGEST_SHA256, KeyProperties.DIGEST_SHA384, KeyProperties.DIGEST_SHA512)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE, KeyProperties.ENCRYPTION_PADDING_RSA_PKCS1)
                    .setSignaturePaddings(KeyProperties.SIGNATURE_PADDING_RSA_PKCS1, KeyProperties.SIGNATURE_PADDING_RSA_PSS)
                    .setCertificateSubject(X500Principal("CN=METZ Display TV"))
                    .setCertificateSerialNumber(BigInteger.ONE)
                    .setCertificateNotBefore(Date(System.currentTimeMillis() - 60_000))
                    .setCertificateNotAfter(Date(System.currentTimeMillis() + 365L * 24 * 3600 * 1000))
                    .build())
                generateKeyPair()
            }
        }
        return store
    }
    private fun digest(certificate: X509Certificate): String = MessageDigest.getInstance("SHA-256")
        .digest(certificate.encoded).joinToString("") { "%02x".format(it.toInt() and 255) }
    fun fingerprint(): String = digest(store().getCertificate(ALIAS) as X509Certificate)
    fun context(pin: String): SSLContext {
        require(StreamProtocol.validPin(pin))
        val expected = pin.lowercase()
        val trust = object : X509TrustManager {
            override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
            override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String) {
                if (chain.isEmpty() || digest(chain[0]) != expected) throw CertificateException("Peer fingerprint mismatch")
                chain[0].checkValidity()
            }
            override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String) = checkClientTrusted(chain, authType)
        }
        val keyStore = store()
        // A default manager could choose retained v1. Expose only the active identity.
        val keys = object : X509ExtendedKeyManager() {
            override fun getClientAliases(type: String?, issuers: Array<out Principal>?): Array<String>? =
                if (type == "RSA") arrayOf(ALIAS) else null
            override fun getServerAliases(type: String?, issuers: Array<out Principal>?) = getClientAliases(type, issuers)
            override fun chooseClientAlias(types: Array<out String>?, issuers: Array<out Principal>?, socket: Socket?): String? =
                if (types?.contains("RSA") == true) ALIAS else null
            override fun chooseServerAlias(type: String?, issuers: Array<out Principal>?, socket: Socket?): String? =
                if (type == "RSA") ALIAS else null
            override fun chooseEngineServerAlias(type: String?, issuers: Array<out Principal>?, engine: SSLEngine?) = chooseServerAlias(type, issuers, null)
            override fun chooseEngineClientAlias(types: Array<out String>?, issuers: Array<out Principal>?, engine: SSLEngine?) = chooseClientAlias(types, issuers, null)
            override fun getCertificateChain(alias: String?): Array<X509Certificate>? =
                if (alias == ALIAS) keyStore.getCertificateChain(ALIAS)?.map { it as X509Certificate }?.toTypedArray() else null
            override fun getPrivateKey(alias: String?): PrivateKey? =
                if (alias == ALIAS) keyStore.getKey(ALIAS, null) as? PrivateKey else null
        }
        return SSLContext.getInstance("TLS").apply { init(arrayOf(keys), arrayOf(trust), null) }
    }
}
