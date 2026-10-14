package com.aerovpn.aerovpn_client

import android.app.Activity
import android.content.Intent
import android.net.VpnService
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.aerovpn.client/vpn"
    private companion object { var nextVpnRequestCode = 0x0F }
    private var pendingRequestCode: Int? = null

    private var pendingConfigJson: String? = null
    private var pendingIp: String? = null
    private var pendingCountry: String? = null
    private var pendingCity: String? = null
    private var pendingClashSecret: String? = null
    private var pendingKillSwitch: Boolean = false
    private var pendingResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "startTunnel" -> {
                    if (pendingResult != null) {
                        result.error("VPN_START_PENDING", "VPN permission request is already pending", null)
                        return@setMethodCallHandler
                    }
                    val configJson = call.argument<String>("config_json") ?: ""
                    val assignedIp = call.argument<String>("assigned_ip") ?: ""
                    val country = call.argument<String>("country") ?: ""
                    val city = call.argument<String>("city") ?: ""
                    val clashSecret = call.argument<String>("clash_secret") ?: ""
                    val killSwitch = call.argument<Boolean>("kill_switch") ?: false

                    val intent = VpnService.prepare(this)
                    if (intent != null) {
                        pendingConfigJson = configJson
                        pendingIp = assignedIp
                        pendingCountry = country
                        pendingCity = city
                        pendingClashSecret = clashSecret
                        pendingKillSwitch = killSwitch
                        pendingResult = result
                        val requestCode = nextVpnRequestCode
                        nextVpnRequestCode = if (requestCode == 0xFFFF) 0x0F else requestCode + 1
                        pendingRequestCode = requestCode
                        try {
                            startActivityForResult(intent, requestCode)
                        } catch (error: Exception) {
                            clearPendingStart()
                            result.error("VPN_PERMISSION_FAILED", error.message, null)
                        }
                    } else {
                        startVpnService(configJson, assignedIp, country, city, clashSecret, killSwitch)
                        // The service starts asynchronously; report the truth and let
                        // the periodic getStats poll resolve "connected"/"error".
                        result.success(mapOf("status" to "connecting"))
                    }
                }
                "stopTunnel" -> {
                    try {
                        AeroVpnService.requestStop()
                        result.success(mapOf("status" to "disconnecting"))
                    } catch (error: Exception) {
                        AeroVpnService.dispatchFailed(error.message ?: "Cannot dispatch VPN stop")
                        result.error("VPN_STOP_FAILED", error.message, null)
                    }
                }
                "cancelPendingStart" -> {
                    cancelPendingStart()
                    result.success(null)
                }
                "getStatus" -> {
                    result.success(mapOf("running" to AeroVpnService.isRunning))
                }
                "getStats" -> {
                    result.success(AeroVpnService.getStatsMap())
                }
                "setKillSwitch" -> {
                    // The app cannot toggle Android's OS-level VPN lockdown.
                    // Cannot toggle OS-level lockdown, but report the truthful
                    // core-level (strict_route) state established at connect.
                    result.success(mapOf("kill_switch" to AeroVpnService.killSwitchEnabled, "supported" to false))
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun startVpnService(configJson: String, ip: String, country: String, city: String, clashSecret: String = "", killSwitch: Boolean = false) {
        AeroVpnService.markStartRequested()
        val intent = Intent(this, AeroVpnService::class.java).apply {
            action = AeroVpnService.ACTION_START
            putExtra(AeroVpnService.EXTRA_CONFIG, configJson)
            putExtra(AeroVpnService.EXTRA_ASSIGNED_IP, ip)
            putExtra(AeroVpnService.EXTRA_COUNTRY, country)
            putExtra(AeroVpnService.EXTRA_CITY, city)
            putExtra(AeroVpnService.EXTRA_CLASH_SECRET, clashSecret)
            putExtra(AeroVpnService.EXTRA_KILL_SWITCH, killSwitch)
        }
        try {
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }
        } catch (error: Exception) {
            AeroVpnService.dispatchFailed(error.message ?: "Cannot dispatch VPN start")
            throw error
        }
    }

    private fun cancelPendingStart() {
        val result = pendingResult ?: return
        val requestCode = pendingRequestCode
        clearPendingStart()
        result.error("VPN_START_CANCELLED", "VPN start cancelled", null)
        if (requestCode != null) finishActivity(requestCode)
    }

    private fun clearPendingStart() {
        pendingRequestCode = null
        pendingConfigJson = null
        pendingIp = null
        pendingCountry = null
        pendingCity = null
        pendingClashSecret = null
        pendingKillSwitch = false
        pendingResult = null
    }

    override fun onDestroy() {
        cancelPendingStart()
        super.onDestroy()
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == pendingRequestCode) {
            try {
                if (resultCode == Activity.RESULT_OK) {
                    if (pendingConfigJson != null) {
                        startVpnService(
                            pendingConfigJson ?: "",
                            pendingIp ?: "",
                            pendingCountry ?: "",
                            pendingCity ?: "",
                            pendingClashSecret ?: "",
                            pendingKillSwitch
                        )
                    }
                    // Service startup is asynchronous; report connecting and let the
                    // periodic getStats poll resolve the final state.
                    pendingResult?.success(mapOf("status" to "connecting"))
                } else {
                    pendingResult?.error("VPN_PERMISSION_DENIED", "User denied VPN permission", null)
                }
            } catch (error: Exception) {
                pendingResult?.error("VPN_START_FAILED", error.message, null)
            } finally {
                clearPendingStart()
            }
        }
    }
}
