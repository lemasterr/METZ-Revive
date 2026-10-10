package com.metzrevive.display

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.util.Base64
import android.view.Surface
import org.json.JSONObject
import java.io.DataInputStream
import java.nio.ByteBuffer
import javax.net.ssl.SSLServerSocket
import javax.net.ssl.SSLSocket

class StreamReceiver(private val surface: Surface, private val pin: String, private val status: (String) -> Unit,
    private val ended: () -> Unit = {}) {
    companion object {
        // Serialize full sessions, including codec release, without blocking the UI.
        private val sessionLock = Any()
        private var retiringDecoder: Thread? = null
    }
    private val telemetry = FrameTelemetry()
    private var lastReportNS = 0L
    private var reportsEnabled = false
    private val renderHandler = android.os.Handler(android.os.Looper.getMainLooper())
    @Volatile private var active = false
    val isRunning get() = active
    @Volatile var lastError = ""
        private set
    @Volatile var listening = false
        private set
    fun trusts(peer: String) = StreamProtocol.validPin(peer) && pin == peer.lowercase()
    @Volatile private var server: SSLServerSocket? = null
    @Volatile private var socket: SSLSocket? = null
    @Volatile private var codec: MediaCodec? = null
    private val frames = FrameInbox()
    private var audio: StreamAudio? = null
    private val audioLock = Any()
    private var network: Thread? = null
    private var decoding: android.os.HandlerThread? = null
    @Volatile private var decodeHandler: android.os.Handler? = null
    private val decoderClosing = java.util.concurrent.atomic.AtomicBoolean(false)
    private val inputBuffers = java.util.ArrayDeque<Int>()
    private val receiptLock = Any()
    private var packetStage = 1
    private val keyframePending = java.util.concurrent.atomic.AtomicBoolean(false)

    private fun receipt(value: Int) = synchronized(receiptLock) { socket?.outputStream?.write(value); Unit }
    fun requestKeyframe() {
        if (!active || socket == null || !keyframePending.compareAndSet(false, true)) return
        Thread({
            try { receipt(0x49) }
            catch (_: Exception) { stop(); status("Соединение прервано. Повторите подключение.") }
            finally { keyframePending.set(false) }
        }, "metz-idr-request").start()
    }

    fun start() {
        check(!active)
        active = true
        network = Thread({ synchronized(sessionLock) {
            var completion = "Подключение завершено. Подключитесь из Manager."
            try {
                retiringDecoder?.let { check(!it.isAlive) { "Previous decoder still retiring" } }
                retiringDecoder = null
                if (!active) return@synchronized
                val listener = (StreamIdentity.context(pin).serverSocketFactory.createServerSocket() as SSLServerSocket)
                server = listener
                // The retiring session closes its accepted socket under sessionLock.
                // Rebind even while TCP retains that closed connection in TIME_WAIT.
                listener.reuseAddress = true
                listener.bind(java.net.InetSocketAddress(47421))
                listener.enabledProtocols = listener.supportedProtocols.filter { it == "TLSv1.2" || it == "TLSv1.3" }.toTypedArray()
                listener.needClientAuth = true
                listener.soTimeout = 1000
                listening = true
                status("Ожидание защищённого подключения")
                var failures = 0
                val deadline = System.nanoTime() + 20_000_000_000L
                while (active && failures < 5 && System.nanoTime() < deadline) {
                    val accepted = try { listener.accept() as SSLSocket } catch (_: java.net.SocketTimeoutException) { continue }
                    socket = accepted
                    try {
                        accepted.tcpNoDelay = true
                        accepted.soTimeout = 10_000
                        accepted.startHandshake()
                    } catch (error: Exception) {
                        accepted.close(); socket = null; failures++
                        lastError = TLSFailure.classify(error)
                        android.util.Log.w("METZ_TLS", lastError)
                        status(TLSFailure.message(lastError))
                        completion = TLSFailure.message(lastError)
                        continue
                    }
                    lastError = ""
                    receipt(0x52) // This receiver supports decoder admission acknowledgements.
                    status("Подключено · второй экран")
                    receive(DataInputStream(accepted.inputStream))
                    break
                }
            } catch (_: java.net.BindException) { recordFailure("LISTENER_BIND"); completion = "Приёмник уже занят. Остановите прошлое подключение и повторите." }
            catch (_: StreamAudioFailure) {
                recordFailure("AUDIO_OUTPUT")
                runCatching { receipt(0xE3) }
                completion = "Звук ТВ недоступен. Подключитесь повторно с выключенной трансляцией звука."
            }
            catch (_: FrameBackpressureTimeout) {
                recordFailure("FRAME_QUEUE_TIMEOUT")
                completion = "ТВ не успевает декодировать кадры. Повторите подключение."
            }
            catch (_: java.net.SocketTimeoutException) {
                if (active) recordFailure("STREAM_READ_TIMEOUT")
                completion = "Поток не поступает. Повторите подключение."
            }
            catch (_: java.io.EOFException) { if (active) recordFailure("STREAM_PEER_CLOSED") }
            catch (_: java.io.IOException) { if (active) recordFailure("STREAM_IO") }
            catch (_: Exception) {
                if (active) {
                    recordFailure("STREAM_FORMAT_STAGE_$packetStage")
                    runCatching { synchronized(receiptLock) { socket?.outputStream?.write(byteArrayOf(0xE4.toByte(), packetStage.toByte())) } }
                }
                completion = "Поток остановлен (формат, этап $packetStage). Повторите подключение."
            }
            finally {
                val notify = active
                stop()
                // Ensure the button sees isRunning=false; decoder release may still be settling.
                if (notify) status(completion)
                decoding?.let {
                    if (it !== Thread.currentThread()) runCatching { it.join(3000) }
                    if (it.isAlive) retiringDecoder = it
                }
                ended()
            }
        } }, "metz-receiver").apply { start() }
    }

    private fun receive(input: DataInputStream) {
        var epoch = 0L
        var lastPTS = -1L
        var waitingIDR = true
        val configuration = VideoSessionGate()
        var parameterSets = ByteArray(0)
        var lastAudioPTS = -1L
        while (active) {
            // Static desktop may be idle; a read timeout ends this session, it never grows buffers.
            packetStage = 1
            val bytes = ByteArray(24); input.readFully(bytes)
            val header = StreamProtocol.header(bytes)
            packetStage = 2
            val payload = ByteArray(header.length); input.readFully(payload)
            when (header.type) {
                1 -> {
                    packetStage = 3
                    require(header.flags == 0)
                    val config = JSONObject(payload.toString(Charsets.UTF_8))
                    val parameters = VideoSessionParameters(config.getInt("width"), config.getInt("height"),
                        config.getInt("fps"), header.epoch, config.optBoolean("audio", false))
                    require(configuration.accept(parameters))
                    parameterSets = configure(config, initialize = codec == null)
                    epoch = header.epoch; waitingIDR = true
                }
                2 -> {
                    packetStage = 4
                    require(codec != null && header.epoch == epoch && header.pts > lastPTS)
                    val idr = StreamProtocol.hasIDR(payload)
                    require((header.flags == 1) == idr)
                    if (waitingIDR) { require(idr); waitingIDR = false }
                    // A short decoder stall must not tear down the desktop. Wait
                    // with bounded memory; TCP then slows the sender without dropping P-frames.
                    if (!frames.offer(EncodedFrame(if (idr) parameterSets + payload else payload, header.pts))) throw FrameBackpressureTimeout()
                    decodeHandler?.post { feedDecoder() }
                    lastPTS = header.pts
                }
                3 -> { packetStage = 6; require(header.length == 0 && header.flags == 0); receipt(0x41) }
                4 -> {
                    packetStage = 5
                    require(header.epoch == epoch && header.pts > lastAudioPTS && audio != null)
                    runCatching { synchronized(audioLock) { audio?.write(payload) } }.getOrElse { throw StreamAudioFailure() }; lastAudioPTS = header.pts
                }
            }
        }
    }

    private fun configure(config: JSONObject, initialize: Boolean): ByteArray {
        val mode = StreamMode(config.getInt("width"), config.getInt("height"), config.getInt("fps"))
        require(mode in StreamMode.candidates && config.getString("profile") == "baseline-" + mode.level)
        fun set(name: String, type: Int): ByteArray {
            val encoded = config.getString(name); require(encoded.length <= 8192)
            return Base64.decode(encoded, Base64.NO_WRAP).also {
                require(it.size in 5..4096 && it.take(4) == listOf<Byte>(0, 0, 0, 1) && (it[4].toInt() and 31) == type)
            }
        }
        val sps = set("sps", 7); val pps = set("pps", 8)
        val parameterSets = sps + pps
        // Feed updated SPS/PPS in-band with the next IDR, without reallocating MediaCodec.
        if (!initialize) {
            require(reportsEnabled == config.optBoolean("telemetry", false))
            return parameterSets
        }
        // Old senders do not request reports and never receive unknown receipts.
        reportsEnabled = config.optBoolean("telemetry", false)
        val info = StreamModes.decoder(mode) ?: error("Hardware AVC mode unavailable")
        val format = MediaFormat.createVideoFormat("video/avc", mode.width, mode.height).apply {
            setByteBuffer("csd-0", ByteBuffer.wrap(sps)); setByteBuffer("csd-1", ByteBuffer.wrap(pps))
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, StreamProtocol.MAX_PAYLOAD + 8192)
            // Declare real-time demand to the codec resource planner; no manual clock changes.
            setInteger(MediaFormat.KEY_PRIORITY, 0)
            setInteger(MediaFormat.KEY_FRAME_RATE, mode.fps)
            setFloat(MediaFormat.KEY_OPERATING_RATE, mode.fps.toFloat())
            if (info.getCapabilitiesForType("video/avc").isFeatureSupported(MediaCodecInfo.CodecCapabilities.FEATURE_LowLatency))
                setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
        }
        if (config.optBoolean("audio", false)) {
            val sink = runCatching { StreamAudio() }.getOrElse { throw StreamAudioFailure() }
            synchronized(audioLock) { if (active) audio = sink else { sink.close(); error("Session stopped") } }
        }
        val decoder = MediaCodec.createByCodecName(info.name)
        val thread = android.os.HandlerThread("metz-decoder", android.os.Process.THREAD_PRIORITY_DISPLAY).apply { start() }
        decoding = thread
        val handler = android.os.Handler(thread.looper)
        decodeHandler = handler
        val configured = java.util.concurrent.CountDownLatch(1)
        var failure: Exception? = null
        handler.post {
            try {
                check(active)
                codec = decoder
                decoder.setCallback(object : MediaCodec.Callback() {
                    override fun onInputBufferAvailable(owner: MediaCodec, index: Int) {
                        if (!active || codec !== owner) return
                        try { inputBuffers.addLast(index); feedDecoder() }
                        catch (error: Exception) { decoderFailed(error) }
                    }
                    override fun onOutputBufferAvailable(owner: MediaCodec, index: Int, info: MediaCodec.BufferInfo) {
                        if (!active || codec !== owner) return
                        try {
                            telemetry.output()
                            owner.releaseOutputBuffer(index, true)
                            if (firstFrame) {
                                firstFrame = false; receipt(0x50)
                                android.util.Log.i("METZStream", "FIRST_FRAME_DECODED")
                            }
                            reportFrames()
                        } catch (error: Exception) { decoderFailed(error) }
                    }
                    override fun onOutputFormatChanged(owner: MediaCodec, format: MediaFormat) = Unit
                    override fun onError(owner: MediaCodec, error: MediaCodec.CodecException) {
                        if (active && codec === owner) decoderFailed(error)
                    }
                }, handler)
                decoder.configure(format, surface, null, 0)
                decoder.setOnFrameRenderedListener({ _, pts, nanoTime ->
                    if (active) telemetry.rendered(pts, nanoTime)
                }, renderHandler)
                decoder.start()
            } catch (error: Exception) {
                failure = error; codec = null
                decoderClosing.set(true)
                runCatching { decoder.release() }
                decodeHandler = null; thread.quitSafely()
            } finally { configured.countDown() }
        }
        check(configured.await(5, java.util.concurrent.TimeUnit.SECONDS)) { "Decoder setup timed out" }
        failure?.let { throw it }
        return parameterSets
    }
    private var firstFrame = true
    // Both available-buffer callbacks and arrival notifications run on the same codec handler.
    // An empty queue sleeps until an event; there is no timed polling of input/output buffers.
    private fun feedDecoder() {
        try {
            val decoder = codec ?: return
            while (active && inputBuffers.isNotEmpty()) {
                val frame = frames.poll(0) ?: break
                val index = inputBuffers.removeFirst()
                val buffer = requireNotNull(decoder.getInputBuffer(index)); buffer.clear()
                require(buffer.remaining() >= frame.bytes.size)
                buffer.put(frame.bytes)
                decoder.queueInputBuffer(index, 0, frame.bytes.size, frame.pts, 0)
                synchronized(receiptLock) { socket?.outputStream?.write(StreamProtocol.admissionReceipt(frame.pts)) }
            }
        } catch (error: Exception) { decoderFailed(error) }
    }
    private fun decoderFailed(error: Exception) {
        if (!active) return
        val code = if (error is MediaCodec.CodecException) "DECODER_CODEC" else "DECODER_BUFFER_OR_STATE"
        recordFailure(code); runCatching { receipt(0xE2) }
        stop(); status("Декодер остановлен ($code). Повторите подключение.")
    }
    private fun reportFrames() {
        val now = System.nanoTime()
        if (!active || !reportsEnabled || now - lastReportNS < 1_000_000_000L) return
        lastReportNS = now
        val report = telemetry.report(now)
        synchronized(receiptLock) { socket?.outputStream?.write(report) }
    }
    private class FrameBackpressureTimeout : Exception()
    private fun recordFailure(code: String) {
        // Fixed stage codes only, never packet contents, peer identity or exception messages.
        lastError = code
        android.util.Log.w("METZStream", code)
    }
    fun stop() {
        active = false
        listening = false
        runCatching { socket?.close() }; socket = null
        runCatching { server?.close() }; server = null
        frames.clear()
        synchronized(audioLock) { audio?.close(); audio = null }
        val handler = decodeHandler
        if (handler != null && decoderClosing.compareAndSet(false, true)) handler.post {
            val decoder = codec; codec = null
            inputBuffers.clear()
            if (decoder != null) {
                runCatching { decoder.setOnFrameRenderedListener(null, null) }
                runCatching { decoder.stop() }; runCatching { decoder.release() }
            }
            decodeHandler = null
            decoding?.quitSafely()
        }
    }
}
