/**
 * tauri android init 之后补 AndroidManifest：
 * - RECORD_AUDIO：语音输入
 * - usesCleartextTraffic：允许局域网 HTTP 供应商（Ollama / LM Studio）
 * 每次 CI 重新生成 Android 工程，因此在这里打补丁而不是提交 gen/。
 */
import { readFileSync, writeFileSync } from 'node:fs'
import { resolve } from 'node:path'

const manifestPath = resolve(
  process.cwd(),
  'src-tauri/gen/android/app/src/main/AndroidManifest.xml'
)

let manifest = readFileSync(manifestPath, 'utf8')

if (!manifest.includes('android.permission.RECORD_AUDIO')) {
  manifest = manifest.replace(
    /<manifest([^>]*)>/,
    '<manifest$1>\n    <uses-permission android:name="android.permission.RECORD_AUDIO" />'
  )
}

if (!manifest.includes('android:usesCleartextTraffic')) {
  manifest = manifest.replace(/<application\b/, '<application android:usesCleartextTraffic="true"')
}

writeFileSync(manifestPath, manifest)
console.log(`Patched ${manifestPath}`)
