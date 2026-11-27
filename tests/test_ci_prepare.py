from __future__ import annotations

import importlib.util
import shutil
import subprocess
import sys
from pathlib import Path

import pytest


def _python_with_pillow() -> str | None:
    if importlib.util.find_spec("PIL") is not None:
        return sys.executable
    for candidate in ("python", "python3"):
        exe = shutil.which(candidate)
        if not exe:
            continue
        probe = subprocess.run(
            [exe, "-c", "import PIL"],
            capture_output=True,
            text=True,
        )
        if probe.returncode == 0:
            return exe
    return None


def test_ci_prepare_generates_icons_and_ime_config(tmp_path: Path) -> None:
    python_exe = _python_with_pillow()
    if python_exe is None:
        pytest.skip("Pillow not available in test environment")

    repo_root = Path(__file__).resolve().parents[1]
    app_copy = tmp_path / "app"
    shutil.copytree(repo_root / "app" / "tool", app_copy / "tool")
    shutil.copytree(repo_root / "app" / "assets", app_copy / "assets")
    (app_copy / "test").mkdir(parents=True)

    # Minimal Android skeleton matching `flutter create`.
    android_app = app_copy / "android" / "app"
    manifest_dir = android_app / "src" / "main"
    manifest_dir.mkdir(parents=True)
    (app_copy / "android" / "settings.gradle.kts").write_text("", encoding="utf-8")
    (app_copy / "android" / "build.gradle.kts").write_text(
        "plugins {\n}\n", encoding="utf-8"
    )
    (android_app / "build.gradle.kts").write_text(
        'plugins {\n    id("com.android.application")\n}\n'
        'android {\n    namespace = "dev.astra.astra_gui"\n'
        "    defaultConfig {\n        minSdk = flutter.minSdkVersion\n    }\n}\n",
        encoding="utf-8",
    )
    (manifest_dir / "AndroidManifest.xml").write_text(
        '<manifest xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <application android:label="astra_gui" android:icon="@mipmap/ic_launcher">\n'
        '        <activity android:name=".MainActivity" />\n'
        "    </application>\n"
        "</manifest>\n",
        encoding="utf-8",
    )

    # Minimal Windows skeleton matching `flutter create`.
    win_runner = app_copy / "windows" / "runner"
    (win_runner / "resources").mkdir(parents=True)
    (win_runner / "main.cpp").write_text(
        'window.Create(L"astra_gui", origin, size);\n', encoding="utf-8"
    )

    script = app_copy / "tool" / "ci_prepare.py"
    subprocess.run([python_exe, str(script), "android"], check=True)
    subprocess.run([python_exe, str(script), "windows"], check=True)

    manifest = (manifest_dir / "AndroidManifest.xml").read_text(encoding="utf-8")
    assert 'android:windowSoftInputMode="adjustResize"' in manifest
    assert 'android:roundIcon="@mipmap/ic_launcher_round"' in manifest
    assert 'android:label="Astra"' in manifest

    res_dir = manifest_dir / "res"
    png_magic = b"\x89PNG\r\n\x1a\n"
    for target in (
        res_dir / "mipmap-xxxhdpi" / "ic_launcher.png",
        res_dir / "mipmap-xxxhdpi" / "ic_launcher_round.png",
        res_dir / "drawable-nodpi" / "ic_launcher_foreground.png",
    ):
        assert target.is_file()
        assert target.read_bytes()[:8] == png_magic

    assert (res_dir / "mipmap-anydpi-v26" / "ic_launcher.xml").is_file()
    assert (res_dir / "mipmap-anydpi-v26" / "ic_launcher_round.xml").is_file()
    assert (res_dir / "values" / "ic_launcher_background.xml").is_file()

    kt = (
        manifest_dir / "kotlin" / "dev" / "astra" / "astra_gui" / "MainActivity.kt"
    ).read_text(encoding="utf-8")
    assert "SOFT_INPUT_ADJUST_RESIZE" in kt
    assert "setDecorFitsSystemWindows(true)" in kt

    ico_path = win_runner / "resources" / "app_icon.ico"
    assert ico_path.is_file()
    assert ico_path.read_bytes()[:4] == b"\x00\x00\x01\x00"
    assert 'L"Astra"' in (win_runner / "main.cpp").read_text(encoding="utf-8")
