package com.aerovpn.aerovpn_client

import android.net.DnsResolver
import android.net.Network
import android.os.Build
import android.os.CancellationSignal
import android.system.ErrnoException
import androidx.annotation.RequiresApi
import io.nekohasekai.libbox.ExchangeContext
import io.nekohasekai.libbox.LocalDNSTransport
import java.net.Inet4Address
import java.net.Inet6Address
import java.net.UnknownHostException
import java.util.concurrent.CancellationException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executor
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/**
 * LocalResolver contract from SagerNet/sing-box-for-android (GPL-3.0),
 * commit bc73504fcb858400a939140ad785ed92f4c9f429. The synchronous Go callback
 * waits for Android's async rawQuery, including cancellation; it must not
 * return before ExchangeContext has a response.
 */
internal class AndroidLocalResolver(private val requireNetwork: () -> Network) : LocalDNSTransport {
    override fun raw(): Boolean = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q

    @RequiresApi(Build.VERSION_CODES.Q)
    override fun exchange(ctx: ExchangeContext, message: ByteArray) {
        val network = requireNetwork()
        val signal = CancellationSignal()
        val completed = AtomicBoolean(false)
        val failure = AtomicReference<Exception?>(null)
        val done = CountDownLatch(1)
        fun complete(action: () -> Unit) {
            if (!completed.compareAndSet(false, true)) return
            try {
                action()
            } catch (error: Exception) {
                failure.set(error)
            } finally {
                done.countDown()
            }
        }
        ctx.onCancel {
            complete {
                signal.cancel()
                throw CancellationException("DNS lookup cancelled")
            }
        }
        DnsResolver.getInstance().rawQuery(
            network, message, DnsResolver.FLAG_NO_RETRY,
            Executor { it.run() }, signal,
            object : DnsResolver.Callback<ByteArray> {
                override fun onAnswer(answer: ByteArray, rcode: Int) {
                    complete {
                        if (rcode == 0) ctx.rawSuccess(answer) else ctx.errorCode(rcode)
                    }
                }
                override fun onError(error: DnsResolver.DnsException) {
                    complete {
                        val cause = error.cause
                        if (cause is ErrnoException) ctx.errnoCode(cause.errno) else throw error
                    }
                }
            },
        )
        done.await()
        failure.get()?.let { throw it }
    }

    override fun lookup(ctx: ExchangeContext, network: String, domain: String) {
        val addresses = try {
            requireNetwork().getAllByName(domain)
        } catch (_: UnknownHostException) {
            ctx.errorCode(3) // NXDOMAIN, matching upstream LocalResolver.
            return
        }
        ctx.success(addresses.filter {
            when {
                network.endsWith("4") -> it is Inet4Address
                network.endsWith("6") -> it is Inet6Address
                else -> true
            }
        }.mapNotNull { it.hostAddress }.joinToString("\n"))
    }
}
