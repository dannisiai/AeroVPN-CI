package com.aerovpn.aerovpn_client

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Adapted from SagerNet/sing-box-for-android DefaultNetworkListener/Monitor
 * (GPL-3.0), commit bc73504fcb858400a939140ad785ed92f4c9f429.
 * Android P+ default callbacks include VPNs: request the best physical network.
 */
internal class AndroidDefaultNetworkMonitor(
    context: Context,
    private val onUpdate: () -> Unit,
) {
    private val connectivity = requireNotNull(context.getSystemService(ConnectivityManager::class.java))
    private val thread = HandlerThread("AeroVpnNetwork").apply { start() }
    private val handler = Handler(thread.looper)
    @Volatile var network: Network? = null
        private set
    @Volatile private var closed = false
    private val initialNetwork = CountDownLatch(1)

    private fun isPhysical(candidate: Network): Boolean {
        val caps = connectivity.getNetworkCapabilities(candidate) ?: return false
        return caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
            caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
    }

    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(candidate: Network) {
            handler.post {
                if (!closed && isPhysical(candidate)) {
                    network = candidate
                    initialNetwork.countDown()
                    onUpdate()
                }
            }
        }
        override fun onLost(candidate: Network) {
            handler.post {
                if (!closed && network == candidate) {
                    network = null
                    onUpdate()
                }
            }
        }
        override fun onCapabilitiesChanged(candidate: Network, caps: NetworkCapabilities) {
            handler.post {
                if (!closed && network == candidate) {
                    if (!isPhysical(candidate)) network = null
                    onUpdate()
                }
            }
        }
        override fun onLinkPropertiesChanged(candidate: Network, properties: LinkProperties) {
            handler.post { if (!closed && network == candidate) onUpdate() }
        }
    }

    fun start() {
        val request = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_RESTRICTED)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
            .build()
        try {
            when {
                Build.VERSION.SDK_INT >= 31 ->
                    connectivity.registerBestMatchingNetworkCallback(request, callback, handler)
                Build.VERSION.SDK_INT >= 28 ->
                    connectivity.requestNetwork(request, callback, handler)
                Build.VERSION.SDK_INT >= 26 ->
                    connectivity.registerDefaultNetworkCallback(callback, handler)
                Build.VERSION.SDK_INT >= 24 ->
                    connectivity.registerDefaultNetworkCallback(callback)
                else -> connectivity.requestNetwork(request, callback)
            }
            // Seed only from a physical active network. Do not guess from the
            // unordered allNetworks list if a VPN is currently the default.
            val active = connectivity.activeNetwork
            if (active != null && isPhysical(active)) network = active
            if (network == null) initialNetwork.await(5, TimeUnit.SECONDS)
            check(network != null) { "No physical default network is available" }
        } catch (error: Exception) {
            close()
            throw error
        }
    }

    fun close() {
        closed = true
        network = null
        runCatching { connectivity.unregisterNetworkCallback(callback) }
        thread.quitSafely()
    }
}
