import os
import re

def patch_pbxproj():
    pbx_path = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "client", "ios", "Runner.xcodeproj", "project.pbxproj"))
    with open(pbx_path, "r", encoding="utf-8") as f:
        content = f.read()

    if "PacketTunnel.appex" in content:
        print("PacketTunnel target already present in project.pbxproj")
        return

    # 1. PBXBuildFile section
    build_files = """\
\t\tAE0000012C10000100000001 /* PacketTunnelProvider.swift in Sources */ = {isa = PBXBuildFile; fileRef = AE0000082C10000100000001 /* PacketTunnelProvider.swift */; };
\t\tAE0000022C10000100000001 /* NetworkExtension.framework in Frameworks */ = {isa = PBXBuildFile; fileRef = AE00000B2C10000100000001 /* NetworkExtension.framework */; };
\t\tAE0000032C10000100000001 /* PacketTunnel.appex in PlugIns */ = {isa = PBXBuildFile; fileRef = AE0000072C10000100000001 /* PacketTunnel.appex */; settings = {ATTRIBUTES = (RemoveHeadersOnCopy, ); }; };
\t\tAE0000042C10000100000001 /* Libbox.xcframework in Frameworks */ = {isa = PBXBuildFile; fileRef = AE00000C2C10000100000001 /* Libbox.xcframework */; };
"""
    content = content.replace("/* Begin PBXBuildFile section */\n", "/* Begin PBXBuildFile section */\n" + build_files)

    # 2. PBXContainerItemProxy section
    container_proxy = """\
\t\tAE0000052C10000100000001 /* PBXContainerItemProxy */ = {
\t\t\tisa = PBXContainerItemProxy;
\t\t\tcontainerPortal = 97C146E61CF9000F007C117D /* Project object */;
\t\t\tproxyType = 1;
\t\t\tremoteGlobalIDString = AE0000132C10000100000001;
\t\t\tremoteInfo = PacketTunnel;
\t\t};
"""
    content = content.replace("/* Begin PBXContainerItemProxy section */\n", "/* Begin PBXContainerItemProxy section */\n" + container_proxy)

    # 3. PBXCopyFilesBuildPhase section
    embed_extensions = """\
\t\tAE0000062C10000100000001 /* Embed App Extensions */ = {
\t\t\tisa = PBXCopyFilesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tdstPath = "";
\t\t\tdstSubfolderSpec = 13;
\t\t\tfiles = (
\t\t\t\tAE0000032C10000100000001 /* PacketTunnel.appex in PlugIns */,
\t\t\t);
\t\t\tname = "Embed App Extensions";
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t};
"""
    content = content.replace("/* Begin PBXCopyFilesBuildPhase section */\n", "/* Begin PBXCopyFilesBuildPhase section */\n" + embed_extensions)

    # 4. PBXFileReference section
    file_refs = """\
\t\tAE0000072C10000100000001 /* PacketTunnel.appex */ = {isa = PBXFileReference; explicitFileType = "wrapper.app-extension"; includeInIndex = 0; path = PacketTunnel.appex; sourceTree = BUILT_PRODUCTS_DIR; };
\t\tAE0000082C10000100000001 /* PacketTunnelProvider.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = PacketTunnelProvider.swift; sourceTree = "<group>"; };
\t\tAE0000092C10000100000001 /* Info.plist */ = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; };
\t\tAE00000A2C10000100000001 /* PacketTunnel.entitlements */ = {isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = PacketTunnel.entitlements; sourceTree = "<group>"; };
\t\tAE00000B2C10000100000001 /* NetworkExtension.framework */ = {isa = PBXFileReference; lastKnownFileType = wrapper.framework; name = NetworkExtension.framework; path = System/Library/Frameworks/NetworkExtension.framework; sourceTree = SDKROOT; };
\t\tAE00000C2C10000100000001 /* Libbox.xcframework */ = {isa = PBXFileReference; lastKnownFileType = wrapper.xcframework; name = Libbox.xcframework; path = Frameworks/Libbox.xcframework; sourceTree = "<group>"; };
\t\tAE00000A2C10000200000001 /* Runner.entitlements */ = {isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = Runner.entitlements; sourceTree = "<group>"; };
"""
    content = content.replace("/* Begin PBXFileReference section */\n", "/* Begin PBXFileReference section */\n" + file_refs)

    # 5. PBXFrameworksBuildPhase for PacketTunnel
    pt_frameworks = """\
\t\tAE00000D2C10000100000001 /* Frameworks */ = {
\t\t\tisa = PBXFrameworksBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t\tAE0000022C10000100000001 /* NetworkExtension.framework in Frameworks */,
\t\t\t\tAE0000042C10000100000001 /* Libbox.xcframework in Frameworks */,
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t};
"""
    content = content.replace("/* Begin PBXFrameworksBuildPhase section */\n", "/* Begin PBXFrameworksBuildPhase section */\n" + pt_frameworks)

    # 6. PBXGroup section
    pt_groups = """\
\t\tAE00000E2C10000100000001 /* PacketTunnel */ = {
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\tAE0000082C10000100000001 /* PacketTunnelProvider.swift */,
\t\t\t\tAE0000092C10000100000001 /* Info.plist */,
\t\t\t\tAE00000A2C10000100000001 /* PacketTunnel.entitlements */,
\t\t\t);
\t\t\tpath = PacketTunnel;
\t\t\tsourceTree = "<group>";
\t\t};
\t\tAE00000F2C10000100000001 /* Frameworks */ = {
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\tAE00000B2C10000100000001 /* NetworkExtension.framework */,
\t\t\t\tAE00000C2C10000100000001 /* Libbox.xcframework */,
\t\t\t);
\t\t\tname = Frameworks;
\t\t\tsourceTree = "<group>";
\t\t};
"""
    content = content.replace("/* Begin PBXGroup section */\n", "/* Begin PBXGroup section */\n" + pt_groups)

    # Add PacketTunnel.appex to Products
    content = re.sub(
        r'(97C146EF1CF9000F007C117D /\* Products \*/ = \{\s+isa = PBXGroup;\s+children = \()',
        r'\1\n\t\t\t\tAE0000072C10000100000001 /* PacketTunnel.appex */,',
        content
    )

    # Add PacketTunnel and Frameworks to Main group
    content = re.sub(
        r'(97C146E51CF9000F007C117D = \{\s+isa = PBXGroup;\s+children = \()',
        r'\1\n\t\t\t\tAE00000E2C10000100000001 /* PacketTunnel */,\n\t\t\t\tAE00000F2C10000100000001 /* Frameworks */,',
        content
    )

    # Add Runner.entitlements to Runner group
    if "AE00000A2C10000200000001 /* Runner.entitlements */" not in content:
        content = re.sub(
            r'(97C146F01CF9000F007C117D /\* Runner \*/ = \{\s+isa = PBXGroup;\s+children = \()',
            r'\1\n\t\t\t\tAE00000A2C10000200000001 /* Runner.entitlements */,',
            content
        )

    # Add CODE_SIGN_ENTITLEMENTS to Runner build configurations
    for conf_id in ["97C147061CF9000F007C117D", "97C147071CF9000F007C117D", "249021D4217E4FDB00AE95B9"]:
        pat = rf'({conf_id} /\* [^*]+ \*/ = \{{[^}}]+buildSettings = \{{)'
        def add_ent(m):
            block = m.group(1)
            if "CODE_SIGN_ENTITLEMENTS" not in block:
                return block + "\n\t\t\t\tCODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements;"
            return block
        content = re.sub(pat, add_ent, content)

    # 7. PBXSourcesBuildPhase and PBXResourcesBuildPhase for PacketTunnel
    pt_sources = """\
\t\tAE0000102C10000100000001 /* Sources */ = {
\t\t\tisa = PBXSourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t\tAE0000012C10000100000001 /* PacketTunnelProvider.swift in Sources */,
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t};
"""
    content = content.replace("/* Begin PBXSourcesBuildPhase section */\n", "/* Begin PBXSourcesBuildPhase section */\n" + pt_sources)

    pt_resources = """\
\t\tAE0000112C10000100000001 /* Resources */ = {
\t\t\tisa = PBXResourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t};
"""
    content = content.replace("/* Begin PBXResourcesBuildPhase section */\n", "/* Begin PBXResourcesBuildPhase section */\n" + pt_resources)

    # 8. PBXTargetDependency section
    pt_dependency = """\
\t\tAE0000122C10000100000001 /* PBXTargetDependency */ = {
\t\t\tisa = PBXTargetDependency;
\t\t\ttarget = AE0000132C10000100000001 /* PacketTunnel */;
\t\t\ttargetProxy = AE0000052C10000100000001 /* PBXContainerItemProxy */;
\t\t};
"""
    content = content.replace("/* Begin PBXTargetDependency section */\n", "/* Begin PBXTargetDependency section */\n" + pt_dependency)

    # 9. Add Embed App Extensions and TargetDependency to Runner target
    # In Runner native target (97C146ED1CF9000F007C117D):
    # buildPhases add AE0000062C10000100000001 /* Embed App Extensions */
    content = re.sub(
        r'(97C146ED1CF9000F007C117D /\* Runner \*/ = \{[^}]+buildPhases = \()',
        r'\1\n\t\t\t\tAE0000062C10000100000001 /* Embed App Extensions */,',
        content
    )
    # dependencies add AE0000122C10000100000001 /* PBXTargetDependency */
    content = re.sub(
        r'(97C146ED1CF9000F007C117D /\* Runner \*/ = \{[^}]+dependencies = \()',
        r'\1\n\t\t\t\tAE0000122C10000100000001 /* PBXTargetDependency */,',
        content
    )

    # 10. PBXNativeTarget for PacketTunnel
    pt_target = """\
\t\tAE0000132C10000100000001 /* PacketTunnel */ = {
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = AE0000142C10000100000001 /* Build configuration list for PBXNativeTarget "PacketTunnel" */;
\t\t\tbuildPhases = (
\t\t\t\tAE0000102C10000100000001 /* Sources */,
\t\t\t\tAE00000D2C10000100000001 /* Frameworks */,
\t\t\t\tAE0000112C10000100000001 /* Resources */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t);
\t\t\tname = PacketTunnel;
\t\t\tproductName = PacketTunnel;
\t\t\tproductReference = AE0000072C10000100000001 /* PacketTunnel.appex */;
\t\t\tproductType = "com.apple.product-type.app-extension";
\t\t};
"""
    content = content.replace("/* Begin PBXNativeTarget section */\n", "/* Begin PBXNativeTarget section */\n" + pt_target)

    # Add PacketTunnel to Project targets
    content = re.sub(
        r'(targets = \(\s+97C146ED1CF9000F007C117D /\* Runner \*/,)',
        r'\1\n\t\t\t\tAE0000132C10000100000001 /* PacketTunnel */,',
        content
    )

    # Add TargetAttributes for PacketTunnel
    content = re.sub(
        r'(TargetAttributes = \{)',
        r'\1\n\t\t\t\t\tAE0000132C10000100000001 = {\n\t\t\t\t\t\tCreatedOnToolsVersion = 14.0;\n\t\t\t\t\t\tSystemCapabilities = {\n\t\t\t\t\t\t\tcom.apple.NetworkExtensions.iOS = {\n\t\t\t\t\t\t\t\tenabled = 1;\n\t\t\t\t\t\t\t};\n\t\t\t\t\t\t};\n\t\t\t\t\t};',
        content
    )

    # 11. XCBuildConfiguration and XCConfigurationList for PacketTunnel
    pt_build_configs = """\
\t\tAE0000152C10000100000001 /* Debug */ = {
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {
\t\t\t\tCLANG_ENABLE_MODULES = YES;
\t\t\t\tCODE_SIGN_ENTITLEMENTS = PacketTunnel/PacketTunnel.entitlements;
\t\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\t\tCURRENT_PROJECT_VERSION = "$(FLUTTER_BUILD_NUMBER)";
\t\t\t\tFRAMEWORK_SEARCH_PATHS = (
\t\t\t\t\t"$(inherited)",
\t\t\t\t\t"$(PROJECT_DIR)/Frameworks",
\t\t\t\t);
\t\t\t\tGENERATE_INFOPLIST_FILE = NO;
\t\t\t\tINFOPLIST_FILE = PacketTunnel/Info.plist;
\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 15.0;
\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (
\t\t\t\t\t"$(inherited)",
\t\t\t\t\t"@executable_path/Frameworks",
\t\t\t\t\t"@executable_path/../../Frameworks",
\t\t\t\t);
\t\t\t\tMARKETING_VERSION = 1.0;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.aerovpn.aerovpnClient.PacketTunnel;
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSKIP_INSTALL = YES;
\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;
\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-Onone";
\t\t\t\tSWIFT_VERSION = 5.0;
\t\t\t\tTARGETED_DEVICE_FAMILY = "1,2";
\t\t\t};
\t\t\tname = Debug;
\t\t};
\t\tAE0000162C10000100000001 /* Release */ = {
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {
\t\t\t\tCLANG_ENABLE_MODULES = YES;
\t\t\t\tCODE_SIGN_ENTITLEMENTS = PacketTunnel/PacketTunnel.entitlements;
\t\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\t\tCURRENT_PROJECT_VERSION = "$(FLUTTER_BUILD_NUMBER)";
\t\t\t\tFRAMEWORK_SEARCH_PATHS = (
\t\t\t\t\t"$(inherited)",
\t\t\t\t\t"$(PROJECT_DIR)/Frameworks",
\t\t\t\t);
\t\t\t\tGENERATE_INFOPLIST_FILE = NO;
\t\t\t\tINFOPLIST_FILE = PacketTunnel/Info.plist;
\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 15.0;
\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (
\t\t\t\t\t"$(inherited)",
\t\t\t\t\t"@executable_path/Frameworks",
\t\t\t\t\t"@executable_path/../../Frameworks",
\t\t\t\t);
\t\t\t\tMARKETING_VERSION = 1.0;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.aerovpn.aerovpnClient.PacketTunnel;
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSKIP_INSTALL = YES;
\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;
\t\t\t\tSWIFT_VERSION = 5.0;
\t\t\t\tTARGETED_DEVICE_FAMILY = "1,2";
\t\t\t};
\t\t\tname = Release;
\t\t};
\t\tAE0000172C10000100000001 /* Profile */ = {
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {
\t\t\t\tCLANG_ENABLE_MODULES = YES;
\t\t\t\tCODE_SIGN_ENTITLEMENTS = PacketTunnel/PacketTunnel.entitlements;
\t\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\t\tCURRENT_PROJECT_VERSION = "$(FLUTTER_BUILD_NUMBER)";
\t\t\t\tFRAMEWORK_SEARCH_PATHS = (
\t\t\t\t\t"$(inherited)",
\t\t\t\t\t"$(PROJECT_DIR)/Frameworks",
\t\t\t\t);
\t\t\t\tGENERATE_INFOPLIST_FILE = NO;
\t\t\t\tINFOPLIST_FILE = PacketTunnel/Info.plist;
\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 15.0;
\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (
\t\t\t\t\t"$(inherited)",
\t\t\t\t\t"@executable_path/Frameworks",
\t\t\t\t\t"@executable_path/../../Frameworks",
\t\t\t\t);
\t\t\t\tMARKETING_VERSION = 1.0;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.aerovpn.aerovpnClient.PacketTunnel;
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSKIP_INSTALL = YES;
\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;
\t\t\t\tSWIFT_VERSION = 5.0;
\t\t\t\tTARGETED_DEVICE_FAMILY = "1,2";
\t\t\t};
\t\t\tname = Profile;
\t\t};
"""
    content = content.replace("/* Begin XCBuildConfiguration section */\n", "/* Begin XCBuildConfiguration section */\n" + pt_build_configs)

    pt_config_list = """\
\t\tAE0000142C10000100000001 /* Build configuration list for PBXNativeTarget "PacketTunnel" */ = {
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\tAE0000152C10000100000001 /* Debug */,
\t\t\t\tAE0000162C10000100000001 /* Release */,
\t\t\t\tAE0000172C10000100000001 /* Profile */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t};
"""
    content = content.replace("/* Begin XCConfigurationList section */\n", "/* Begin XCConfigurationList section */\n" + pt_config_list)

    with open(pbx_path, "w", encoding="utf-8") as f:
        f.write(content)
    print("Successfully patched project.pbxproj with PacketTunnel target!")


def verify_libbox_framework():
    """Reject placeholder Libbox.xcframework stubs before Xcode links them.

    A stub slice (~100 bytes, header declaring only the pre-v1.13 LibboxNewService
    API) satisfies the project's file references but cannot compile, and a missing
    framework silently drops the tunnel engine. Reuse the shared verifier so the
    shell/Python/CI paths all apply identical rules.
    """
    import subprocess
    import sys

    script_dir = os.path.dirname(os.path.abspath(__file__))
    framework = os.path.abspath(
        os.path.join(script_dir, "..", "client", "ios", "Frameworks", "Libbox.xcframework")
    )
    verifier = os.path.join(script_dir, "verify_upstream_artifact.py")
    result = subprocess.run([sys.executable, verifier, "--xcframework", framework])
    if result.returncode != 0:
        raise SystemExit(
            "Libbox.xcframework failed verification. Build it with "
            "core/scripts/build_apple_xcframework.sh before patching the Xcode project."
        )


if __name__ == "__main__":
    verify_libbox_framework()
    patch_pbxproj()
