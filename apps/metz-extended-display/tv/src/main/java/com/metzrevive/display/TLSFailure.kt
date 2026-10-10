package com.metzrevive.display

/** Report known causes without printing addresses, pins or certificate data. */
object TLSFailure {
    fun classify(error: Throwable): String {
        val chain = generateSequence(error) { it.cause }.take(8).toList()
        val names = chain.joinToString(" ") { it.javaClass.simpleName }
        val detail = chain.joinToString(" ") { it.message.orEmpty() }.lowercase()
        return when {
            "fingerprint mismatch" in detail -> "PIN_MISMATCH"
            "CertificateExpired" in names || "CertificateNotYetValid" in names -> "CERTIFICATE_TIME"
            "SocketTimeout" in names -> "TIMEOUT"
            "InvalidKey" in names || "SignatureException" in names || "signature" in detail -> "TLS_SIGNATURE"
            "certificate" in detail && ("empty" in detail || "required" in detail) -> "CLIENT_CERTIFICATE"
            "Certificate" in names -> "CERTIFICATE"
            else -> "TLS_HANDSHAKE"
        }
    }
    fun message(code: String): String = when (code) {
        "PIN_MISMATCH" -> "Ключ Mac отличается от подтверждённого. Подготовьте подключение заново."
        "CERTIFICATE_TIME" -> "Сертификат вне срока действия. Проверьте дату Mac и ТВ."
        "TIMEOUT" -> "Mac не завершил подключение за 10 секунд. Проверьте сеть."
        "TLS_SIGNATURE" -> "Ошибка TLS-подписи. Подключение остановлено; обновите Manager и Display."
        "CLIENT_CERTIFICATE" -> "Mac не предоставил сертификат. Выберите папку ключа в Manager."
        "CERTIFICATE" -> "Сертификат Mac не прошёл проверку. Сверьте ключ и дату устройств."
        else -> "Ошибка согласования TLS. Доверие и передача изображения не подтверждены."
    }
}
