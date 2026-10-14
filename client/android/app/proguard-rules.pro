# Upstream sing-box / libbox reflection keep rules
# AeroVpnService.kt uses dynamic reflection to load and interact with these classes at runtime.
-keep class io.nekohasekai.libbox.** { *; }
-keep interface io.nekohasekai.libbox.** { *; }
-dontwarn io.nekohasekai.libbox.**

# Go runtime / gomobile support classes
-keep class go.** { *; }
-dontwarn go.**

# AeroVPN reflection entry points and native service targets
-keep class com.aerovpn.aerovpn_client.AeroVpnService { *; }
-keep class com.aerovpn.aerovpn_client.MainActivity { *; }
