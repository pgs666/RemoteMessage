from __future__ import annotations

import plistlib
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


APP_NAME_EN = "RemoteMessage"
APP_NAME_ZH = "RemoteMessage"
ANDROID_CHANNEL = "cn.ac.studio.rmc/icon_mode"
ANDROID_APPLICATION_ID = "cn.ac.studio.rmc"
ANDROID_NS = "http://schemas.android.com/apk/res/android"


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: python client/configure_client_app_identity.py <flutter_app_dir>")
        return 1

    app_dir = Path(sys.argv[1]).resolve()
    if not app_dir.exists():
        raise FileNotFoundError(f"Flutter app directory not found: {app_dir}")

    configure_android(app_dir)
    configure_ios(app_dir)
    configure_linux(app_dir)
    configure_windows(app_dir)

    print(f"Configured app identity for {app_dir}")
    return 0


def configure_android(app_dir: Path) -> None:
    android_main = app_dir / "android" / "app" / "src" / "main"
    if not android_main.exists():
        return

    patch_android_package_id(app_dir)
    write_android_strings(android_main)
    patch_android_manifest(android_main / "AndroidManifest.xml")
    patch_android_main_activity(android_main)


def patch_android_package_id(app_dir: Path) -> None:
    gradle_groovy = app_dir / "android" / "app" / "build.gradle"
    gradle_kts = app_dir / "android" / "app" / "build.gradle.kts"

    for gradle_file in [gradle_groovy, gradle_kts]:
        if not gradle_file.exists():
            continue
        text = gradle_file.read_text(encoding="utf-8")
        namespace_replacement = (
            f'namespace = "{ANDROID_APPLICATION_ID}"'
            if gradle_file.suffix == ".kts"
            else f'namespace "{ANDROID_APPLICATION_ID}"'
        )
        app_id_replacement = (
            f'applicationId = "{ANDROID_APPLICATION_ID}"'
            if gradle_file.suffix == ".kts"
            else f'applicationId "{ANDROID_APPLICATION_ID}"'
        )
        text = re.sub(
            r'namespace\s*[= ]\s*["\'][^"\']*["\']',
            namespace_replacement,
            text,
        )
        text = re.sub(
            r'applicationId\s*[= ]\s*["\'][^"\']*["\']',
            app_id_replacement,
            text,
        )
        gradle_file.write_text(text, encoding="utf-8")


def write_android_strings(android_main: Path) -> None:
    values_dir = android_main / "res" / "values"
    values_zh_dir = android_main / "res" / "values-zh-rCN"
    values_dir.mkdir(parents=True, exist_ok=True)
    values_zh_dir.mkdir(parents=True, exist_ok=True)

    (values_dir / "strings.xml").write_text(
        f"""<?xml version=\"1.0\" encoding=\"utf-8\"?>
<resources>
    <string name=\"app_name\">{APP_NAME_EN}</string>
</resources>
""",
        encoding="utf-8",
    )
    (values_zh_dir / "strings.xml").write_text(
        f"""<?xml version=\"1.0\" encoding=\"utf-8\"?>
<resources>
    <string name=\"app_name\">{APP_NAME_ZH}</string>
</resources>
""",
        encoding="utf-8",
    )


def patch_android_manifest(manifest_path: Path) -> None:
    if not manifest_path.exists():
        return

    ET.register_namespace("android", ANDROID_NS)
    tree = ET.parse(manifest_path)
    root = tree.getroot()
    application = root.find("application")
    if application is None:
        return

    application.set(ns("label"), "@string/app_name")
    application.set(ns("icon"), "@mipmap/ic_launcher_default")
    application.set(ns("roundIcon"), "@mipmap/ic_launcher_default")

    main_activity = find_main_activity(application)
    if main_activity is not None:
        strip_launcher_intent_filters(main_activity)

    ensure_activity_alias(
        application,
        alias_name=".MainActivityDefault",
        icon="@mipmap/ic_launcher_default",
        enabled=True,
    )
    ensure_activity_alias(
        application,
        alias_name=".MainActivityLight",
        icon="@mipmap/ic_launcher_light",
        enabled=False,
    )
    ensure_activity_alias(
        application,
        alias_name=".MainActivityDark",
        icon="@mipmap/ic_launcher_dark",
        enabled=False,
    )

    tree.write(manifest_path, encoding="utf-8", xml_declaration=True)


def find_main_activity(application: ET.Element) -> ET.Element | None:
    for activity in application.findall("activity"):
        name = (activity.get(ns("name")) or "").strip()
        if name.endswith(".MainActivity") or name == "MainActivity":
            return activity
    return None


def strip_launcher_intent_filters(activity: ET.Element) -> None:
    for intent_filter in list(activity.findall("intent-filter")):
        has_main = any(
            (action.get(ns("name")) or "").strip() == "android.intent.action.MAIN"
            for action in intent_filter.findall("action")
        )
        has_launcher = any(
            (category.get(ns("name")) or "").strip() == "android.intent.category.LAUNCHER"
            for category in intent_filter.findall("category")
        )
        if has_main and has_launcher:
            activity.remove(intent_filter)


def ensure_activity_alias(application: ET.Element, alias_name: str, icon: str, enabled: bool) -> None:
    alias = None
    for node in application.findall("activity-alias"):
        if (node.get(ns("name")) or "").strip() == alias_name:
            alias = node
            break
    if alias is None:
        alias = ET.SubElement(application, "activity-alias")

    alias.set(ns("name"), alias_name)
    alias.set(ns("enabled"), "true" if enabled else "false")
    alias.set(ns("exported"), "true")
    alias.set(ns("icon"), icon)
    alias.set(ns("targetActivity"), ".MainActivity")

    for intent_filter in list(alias.findall("intent-filter")):
        alias.remove(intent_filter)

    intent_filter = ET.SubElement(alias, "intent-filter")
    action = ET.SubElement(intent_filter, "action")
    action.set(ns("name"), "android.intent.action.MAIN")
    category = ET.SubElement(intent_filter, "category")
    category.set(ns("name"), "android.intent.category.LAUNCHER")


def patch_android_main_activity(android_main: Path) -> None:
    candidates = sorted((android_main / "kotlin").glob("**/MainActivity.kt"))
    if not candidates:
        candidates = sorted((android_main / "java").glob("**/MainActivity.kt"))
    if not candidates:
        return

    kotlin_root = android_main / "kotlin"
    kotlin_root.mkdir(parents=True, exist_ok=True)
    target_dir = kotlin_root / Path(*ANDROID_APPLICATION_ID.split("."))
    target_dir.mkdir(parents=True, exist_ok=True)
    target_main_activity = target_dir / "MainActivity.kt"
    target_main_activity.write_text(build_main_activity_kotlin(ANDROID_APPLICATION_ID), encoding="utf-8")

    for source_file in candidates:
        if source_file.resolve() != target_main_activity.resolve():
            source_file.unlink(missing_ok=True)


def build_main_activity_kotlin(package_name: str) -> str:
    return f"""package {package_name}

import android.content.ComponentName
import android.content.pm.PackageManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {{
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {{
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_NAME)
            .setMethodCallHandler {{ call, result ->
                if (call.method != "setLauncherIconMode") {{
                    result.notImplemented()
                    return@setMethodCallHandler
                }}

                val mode = call.argument<String>("mode") ?: "default"
                try {{
                    applyLauncherIconMode(mode)
                    result.success(true)
                }} catch (t: Throwable) {{
                    result.error("icon_mode_error", t.message ?: "unknown error", null)
                }}
            }}
    }}

    private fun applyLauncherIconMode(mode: String) {{
        val appPackage = applicationContext.packageName
        val pm = applicationContext.packageManager
        val flags = PackageManager.DONT_KILL_APP

        val defaultAlias = ComponentName(appPackage, "$appPackage.MainActivityDefault")
        val lightAlias = ComponentName(appPackage, "$appPackage.MainActivityLight")
        val darkAlias = ComponentName(appPackage, "$appPackage.MainActivityDark")

        when (mode.lowercase()) {{
            "light" -> {{
                setAliasEnabled(pm, defaultAlias, false, flags)
                setAliasEnabled(pm, lightAlias, true, flags)
                setAliasEnabled(pm, darkAlias, false, flags)
            }}
            "dark" -> {{
                setAliasEnabled(pm, defaultAlias, false, flags)
                setAliasEnabled(pm, lightAlias, false, flags)
                setAliasEnabled(pm, darkAlias, true, flags)
            }}
            else -> {{
                setAliasEnabled(pm, defaultAlias, true, flags)
                setAliasEnabled(pm, lightAlias, false, flags)
                setAliasEnabled(pm, darkAlias, false, flags)
            }}
        }}
    }}

    private fun setAliasEnabled(pm: PackageManager, alias: ComponentName, enabled: Boolean, flags: Int) {{
        pm.setComponentEnabledSetting(
            alias,
            if (enabled) PackageManager.COMPONENT_ENABLED_STATE_ENABLED
            else PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
            flags
        )
    }}

    companion object {{
        private const val CHANNEL_NAME = "{ANDROID_CHANNEL}"
    }}
}}
"""


def configure_ios(app_dir: Path) -> None:
    info_plist = app_dir / "ios" / "Runner" / "Info.plist"
    if not info_plist.exists():
        return

    with info_plist.open("rb") as f:
        data = plistlib.load(f)

    data["CFBundleDisplayName"] = APP_NAME_EN
    data["CFBundleName"] = APP_NAME_EN
    data.setdefault("NSContactsUsageDescription", "Use contacts to display names for phone numbers.")
    data.setdefault("NSCameraUsageDescription", "Use camera to scan onboarding QR code.")
    data.setdefault("NSPhotoLibraryUsageDescription", "Select QR code image for onboarding.")
    data.setdefault("NSPhotoLibraryAddUsageDescription", "Save exported files when needed.")

    with info_plist.open("wb") as f:
        plistlib.dump(data, f, sort_keys=False)


def configure_linux(app_dir: Path) -> None:
    cmake = app_dir / "linux" / "CMakeLists.txt"
    if cmake.exists():
        text = cmake.read_text(encoding="utf-8")
        text = re.sub(r'set\(BINARY_NAME\s+"[^"]*"\)', 'set(BINARY_NAME "RemoteMessage")', text)
        cmake.write_text(text, encoding="utf-8")

    app_cc = app_dir / "linux" / "runner" / "my_application.cc"
    if app_cc.exists():
        text = app_cc.read_text(encoding="utf-8")
        text = re.sub(r'gtk_header_bar_set_title\(header_bar,\s*"[^"]*"\);', f'gtk_header_bar_set_title(header_bar, "{APP_NAME_EN}");', text)
        text = re.sub(r'gtk_window_set_title\(window,\s*"[^"]*"\);', f'gtk_window_set_title(window, "{APP_NAME_EN}");', text)
        app_cc.write_text(text, encoding="utf-8")


def configure_windows(app_dir: Path) -> None:
    cmake = app_dir / "windows" / "CMakeLists.txt"
    if cmake.exists():
        text = cmake.read_text(encoding="utf-8")
        text = re.sub(r'set\(BINARY_NAME\s+"[^"]*"\)', 'set(BINARY_NAME "RemoteMessage")', text)
        cmake.write_text(text, encoding="utf-8")

    main_cpp = app_dir / "windows" / "runner" / "main.cpp"
    if main_cpp.exists():
        text = main_cpp.read_text(encoding="utf-8")
        text = re.sub(r'CreateAndShow\(L"[^"]*"', f'CreateAndShow(L"{APP_NAME_EN}"', text)
        main_cpp.write_text(text, encoding="utf-8")

    resources_h = app_dir / "windows" / "runner" / "resources.h"
    if resources_h.exists():
        text = resources_h.read_text(encoding="utf-8")
        text = re.sub(r'#define\s+APP_NAME\s+"[^"]*"', f'#define APP_NAME "{APP_NAME_EN}"', text)
        resources_h.write_text(text, encoding="utf-8")

    runner_rc = app_dir / "windows" / "runner" / "Runner.rc"
    if runner_rc.exists():
        text = runner_rc.read_text(encoding="utf-8")
        text = re.sub(r'VALUE "FileDescription",\s*"[^"]*"', f'VALUE "FileDescription", "{APP_NAME_EN}"', text)
        text = re.sub(r'VALUE "InternalName",\s*"[^"]*"', 'VALUE "InternalName", "RemoteMessage"', text)
        text = re.sub(r'VALUE "OriginalFilename",\s*"[^"]*"', 'VALUE "OriginalFilename", "RemoteMessage.exe"', text)
        text = re.sub(r'VALUE "ProductName",\s*"[^"]*"', f'VALUE "ProductName", "{APP_NAME_EN}"', text)
        runner_rc.write_text(text, encoding="utf-8")


def ns(name: str) -> str:
    return f"{{{ANDROID_NS}}}{name}"


if __name__ == "__main__":
    raise SystemExit(main())
