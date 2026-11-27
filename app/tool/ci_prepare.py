#!/usr/bin/env python3
"""Prepare Flutter platform scaffolding on a CI runner.

The repository intentionally does not commit android/ or windows/ directories.
`flutter create` generates them, then this script adds the Android-specific
Chaquopy bridge, permissions and desktop title tweaks.
"""

from __future__ import annotations

import re
import shutil
import sys
from pathlib import Path

APP = Path(__file__).resolve().parents[1]
TEMPLATES = Path(__file__).resolve().parent / "templates" / "android"
ICON_SOURCE = APP / "assets" / "app_icon.png"
CHAQUOPY_PLUGIN_VERSION = "17.2.0"
PYTHON_VERSION = "3.12"

ANDROID_MIPMAPS = {
    "mipmap-mdpi": 48,
    "mipmap-hdpi": 72,
    "mipmap-xhdpi": 96,
    "mipmap-xxhdpi": 144,
    "mipmap-xxxhdpi": 192,
}


def fail(message: str) -> None:
    print(f"ci_prepare: ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def patch_android_gradle(build_file: Path) -> None:
    text = build_file.read_text(encoding="utf-8")
    kts = build_file.suffix == ".kts"
    if "com.chaquo.python" not in text:
        if "plugins {" not in text:
            fail(f"could not find plugins block in {build_file}")
        plugin = (
            "id(\"com.chaquo.python\")"
            if kts
            else "id 'com.chaquo.python'"
        )
        anchor = (
            'id("com.android.application")'
            if kts
            else "id 'com.android.application'"
        )
        if anchor in text:
            text = text.replace(anchor, anchor + "\n    " + plugin, 1)
        else:
            text = text.replace("plugins {", "plugins {\n    " + plugin, 1)

    text, count = re.subn(
        r"minSdk\s*=\s*flutter\.minSdkVersion",
        "minSdk = 24",
        text,
    )
    if count == 0:
        text, count = re.subn(
            r"minSdk\s+flutter\.minSdkVersion",
            "minSdk 24",
            text,
        )
    if count == 0 and "minSdk" not in text:
        if kts:
            text = text.replace(
                "defaultConfig {",
                "defaultConfig {\n            minSdk = 24",
                1,
            )
        else:
            text = text.replace(
                "defaultConfig {",
                "defaultConfig {\n            minSdk 24",
                1,
            )

    if "signingConfigs.getByName(\"debug\")" not in text and (
        "signingConfig signingConfigs.debug" not in text
    ):
        if kts:
            text += (
                "\nandroid {\n"
                "    buildTypes {\n"
                "        release {\n"
                "            signingConfig = signingConfigs.getByName(\"debug\")\n"
                "        }\n"
                "    }\n"
                "}\n"
            )
        else:
            text += (
                "\nandroid {\n"
                "    buildTypes {\n"
                "        release {\n"
                "            signingConfig signingConfigs.debug\n"
                "        }\n"
                "    }\n"
                "}\n"
            )

    if "abiFilters" not in text:
        if kts:
            text += (
                "\nandroid {\n"
                "    defaultConfig {\n"
                "        ndk {\n"
                "            abiFilters += listOf(\"arm64-v8a\")\n"
                "        }\n"
                "    }\n"
                "}\n"
            )
        else:
            text += (
                "\nandroid {\n"
                "    defaultConfig {\n"
                "        ndk {\n"
                "            abiFilters 'arm64-v8a'\n"
                "        }\n"
                "    }\n"
                "}\n"
            )

    if "chaquopy {" in text:
        build_file.write_text(text, encoding="utf-8")
        return

    if kts:
        text += (
            "\nchaquopy {\n"
            "    defaultConfig {\n"
            f'        version = "{PYTHON_VERSION}"\n'
            '        buildPython("python3")\n'
            "    }\n"
            "}\n"
        )
    else:
        text += (
            "\nchaquopy {\n"
            "    defaultConfig {\n"
            f'        version = "{PYTHON_VERSION}"\n'
            '        buildPython "python3"\n'
            "    }\n"
            "}\n"
        )
    build_file.write_text(text, encoding="utf-8")


def android_namespace(build_file: Path) -> str:
    text = build_file.read_text(encoding="utf-8")
    match = re.search(r'namespace\s*=\s*"([^"]+)"', text)
    if not match:
        match = re.search(r'namespace\s+"([^"]+)"', text)
    if not match:
        match = re.search(r'applicationId\s*=\s*"([^"]+)"', text)
    if not match:
        match = re.search(r'applicationId\s+"([^"]+)"', text)
    if not match:
        fail("could not determine Android namespace/applicationId")
    return match.group(1)


def write_main_activity(namespace: str) -> None:
    source = (TEMPLATES / "MainActivity.kt").read_text(encoding="utf-8")
    source = source.replace("__PACKAGE__", namespace)
    target_dir = (
        APP
        / "android"
        / "app"
        / "src"
        / "main"
        / "kotlin"
        / Path(*namespace.split("."))
    )
    target_dir.mkdir(parents=True, exist_ok=True)
    (target_dir / "MainActivity.kt").write_text(source, encoding="utf-8")
    java_activity = target_dir / "MainActivity.java"
    if java_activity.exists():
        java_activity.unlink()

    python_dir = APP / "android" / "app" / "src" / "main" / "python"
    python_dir.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(
        TEMPLATES / "astra_runner.py",
        python_dir / "astra_runner.py",
    )


def patch_manifest() -> None:
    manifest = APP / "android" / "app" / "src" / "main" / "AndroidManifest.xml"
    text = manifest.read_text(encoding="utf-8")
    permissions = [
        "android.permission.INTERNET",
        "android.permission.ACCESS_NETWORK_STATE",
        "android.permission.ACCESS_WIFI_STATE",
        "android.permission.CHANGE_WIFI_MULTICAST_STATE",
    ]
    missing = [p for p in permissions if f'android:name="{p}"' not in text]
    if missing:
        entries = "\n".join(
            f'    <uses-permission android:name="{permission}" />'
            for permission in missing
        )
        text = re.sub(
            r"(<manifest[^>]*>)",
            r"\1\n" + entries,
            text,
            count=1,
        )
    text = re.sub(r'android:label="[^"]*"', 'android:label="Astra"', text)
    if 'android:roundIcon="' not in text:
        text = re.sub(
            r'android:icon="@mipmap/ic_launcher"',
            'android:icon="@mipmap/ic_launcher"\n        android:roundIcon="@mipmap/ic_launcher_round"',
            text,
            count=1,
        )
    if 'android:windowSoftInputMode="' in text:
        text = re.sub(
            r'android:windowSoftInputMode="[^"]*"',
            'android:windowSoftInputMode="adjustResize"',
            text,
        )
    else:
        text = re.sub(
            r"(<activity\b)",
            r'\1\n            android:windowSoftInputMode="adjustResize"',
            text,
            count=1,
        )
    if "usesCleartextTraffic" not in text:
        text = re.sub(
            r"<application\b",
            '<application\n        android:usesCleartextTraffic="true"',
            text,
            count=1,
        )
    manifest.write_text(text, encoding="utf-8")


def _load_icon_image():
    if not ICON_SOURCE.exists():
        return None
    try:
        from PIL import Image, ImageDraw  # type: ignore
    except ImportError:
        fail("Pillow is required to generate app icons (pip install pillow)")
    img = Image.open(ICON_SOURCE).convert("RGBA")
    side = min(img.size)
    left = (img.width - side) // 2
    top = (img.height - side) // 2
    return img.crop((left, top, left + side, top + side)), Image, ImageDraw


def _corner_hex(img) -> str:
    w, h = img.size
    samples = [
        img.getpixel((0, 0)),
        img.getpixel((w - 1, 0)),
        img.getpixel((0, h - 1)),
        img.getpixel((w - 1, h - 1)),
    ]
    r = sum(p[0] for p in samples) // len(samples)
    g = sum(p[1] for p in samples) // len(samples)
    b = sum(p[2] for p in samples) // len(samples)
    return f"#{r:02X}{g:02X}{b:02X}"


def patch_android_icons() -> None:
    loaded = _load_icon_image()
    if loaded is None:
        print("ci_prepare: app/assets/app_icon.png not found; keeping default icons")
        return
    square, Image, ImageDraw = loaded
    res_dir = APP / "android" / "app" / "src" / "main" / "res"
    res_dir.mkdir(parents=True, exist_ok=True)

    for folder, size in ANDROID_MIPMAPS.items():
        out_dir = res_dir / folder
        out_dir.mkdir(parents=True, exist_ok=True)
        resized = square.resize((size, size), Image.Resampling.LANCZOS)
        resized.save(out_dir / "ic_launcher.png", format="PNG")

        mask = Image.new("L", (size, size), 0)
        ImageDraw.Draw(mask).ellipse((0, 0, size - 1, size - 1), fill=255)
        round_icon = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        round_icon.paste(resized, (0, 0), mask)
        round_icon.save(out_dir / "ic_launcher_round.png", format="PNG")

    # Adaptive icon (API 26+): keep full avatar inside 72dp safe zone on 108dp canvas.
    drawable_dir = res_dir / "drawable-nodpi"
    drawable_dir.mkdir(parents=True, exist_ok=True)
    fg_canvas = Image.new("RGBA", (432, 432), (0, 0, 0, 0))
    fg_inner = square.resize((300, 300), Image.Resampling.LANCZOS)
    fg_canvas.paste(fg_inner, (66, 66), fg_inner)
    fg_canvas.save(drawable_dir / "ic_launcher_foreground.png", format="PNG")

    values_dir = res_dir / "values"
    values_dir.mkdir(parents=True, exist_ok=True)
    bg_hex = _corner_hex(square)
    (values_dir / "ic_launcher_background.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        "<resources>\n"
        f'    <color name="ic_launcher_background">{bg_hex}</color>\n'
        "</resources>\n",
        encoding="utf-8",
    )

    anydpi_dir = res_dir / "mipmap-anydpi-v26"
    anydpi_dir.mkdir(parents=True, exist_ok=True)
    adaptive_xml = (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <background android:drawable="@color/ic_launcher_background" />\n'
        '    <foreground android:drawable="@drawable/ic_launcher_foreground" />\n'
        "</adaptive-icon>\n"
    )
    (anydpi_dir / "ic_launcher.xml").write_text(adaptive_xml, encoding="utf-8")
    (anydpi_dir / "ic_launcher_round.xml").write_text(adaptive_xml, encoding="utf-8")
    print(f"ci_prepare: Android icons generated (bg={bg_hex})")


def patch_windows_icon() -> None:
    loaded = _load_icon_image()
    if loaded is None:
        return
    square, Image, _ = loaded
    icon_target = APP / "windows" / "runner" / "resources" / "app_icon.ico"
    icon_target.parent.mkdir(parents=True, exist_ok=True)
    sizes = [(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)]
    base = square.resize((256, 256), Image.Resampling.LANCZOS)
    base.save(icon_target, format="ICO", sizes=sizes)
    print(f"ci_prepare: Windows icon updated ({icon_target})")


def patch_root_plugin() -> None:
    for name in ("build.gradle.kts", "build.gradle"):
        root_build = APP / "android" / name
        if not root_build.exists():
            continue
        text = root_build.read_text(encoding="utf-8")
        if "com.chaquo.python" in text:
            return
        kts = root_build.suffix == ".kts"
        declaration = (
            f'    id("com.chaquo.python") version "{CHAQUOPY_PLUGIN_VERSION}" apply false\n'
            if kts
            else f"    id 'com.chaquo.python' version '{CHAQUOPY_PLUGIN_VERSION}' apply false\n"
        )
        if "plugins {" in text:
            text = text.replace("plugins {", "plugins {\n" + declaration, 1)
        else:
            text = "plugins {\n" + declaration + "}\n\n" + text
        root_build.write_text(text, encoding="utf-8")
        return
    fail("could not find top-level build.gradle(.kts)")


def prepare_android() -> None:
    if not (APP / "android").is_dir():
        fail("android/ is missing; run `flutter create --platforms=android .` first")
    settings_kts = APP / "android" / "settings.gradle.kts"
    settings_groovy = APP / "android" / "settings.gradle"
    if not settings_kts.exists() and not settings_groovy.exists():
        fail("could not find settings.gradle(.kts)")

    patch_root_plugin()
    build_kts = APP / "android" / "app" / "build.gradle.kts"
    build_groovy = APP / "android" / "app" / "build.gradle"
    build_file = build_kts if build_kts.exists() else build_groovy
    if not build_file.exists():
        fail("could not find app/build.gradle(.kts)")

    namespace = android_namespace(build_file)
    patch_android_gradle(build_file)
    write_main_activity(namespace)
    patch_manifest()
    patch_android_icons()
    print(f"ci_prepare: Android ready (namespace={namespace})")


def prepare_windows() -> None:
    main_cpp = APP / "windows" / "runner" / "main.cpp"
    if not main_cpp.exists():
        fail("windows/runner/main.cpp is missing; run flutter create first")
    text = main_cpp.read_text(encoding="utf-8")
    text = text.replace('L"astra_gui"', 'L"Astra"')
    main_cpp.write_text(text, encoding="utf-8")
    patch_windows_icon()
    print("ci_prepare: Windows runner title and icon updated")


def main() -> None:
    if len(sys.argv) != 2 or sys.argv[1] not in {"android", "windows"}:
        print("usage: ci_prepare.py <android|windows>", file=sys.stderr)
        raise SystemExit(2)
    template_test = APP / "test" / "widget_test.dart"
    if template_test.exists():
        template_test.unlink()
    if sys.argv[1] == "android":
        prepare_android()
    else:
        prepare_windows()


if __name__ == "__main__":
    main()
