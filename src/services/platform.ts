import { invoke } from '@tauri-apps/api/core'
import { isTauri } from './api/transport.js'

const bytesToBase64 = (bytes: Uint8Array): string => {
  let binary = ''
  const chunk = 0x8000
  for (let index = 0; index < bytes.length; index += chunk) {
    binary += String.fromCharCode(...bytes.subarray(index, index + chunk))
  }
  return btoa(binary)
}

/** 在系统浏览器打开外链；Tauri 用 opener 插件，Web 用新窗口 */
export const openExternal = async (url: string): Promise<void> => {
  if (!isTauri()) {
    window.open(url, '_blank', 'noopener,noreferrer')
    return
  }
  const { openUrl } = await import('@tauri-apps/plugin-opener')
  await openUrl(url)
}

/** 保存文件到用户选择的位置；返回是否成功保存（用户取消为 false） */
/** 打开本地 Blob URL：Web 新窗口预览；Tauri 改为另存为 */
export const openLocalBlob = async (url: string, fileName: string): Promise<void> => {
  if (!isTauri()) {
    window.open(url, '_blank', 'noreferrer')
    return
  }
  const blob = await fetch(url).then((response) => response.blob())
  await saveBlob(blob, fileName)
}

export const saveBlob = async (blob: Blob, fileName: string): Promise<boolean> => {
  if (!isTauri()) {
    const url = URL.createObjectURL(blob)
    const link = document.createElement('a')
    link.href = url
    link.download = fileName
    link.click()
    window.setTimeout(() => URL.revokeObjectURL(url), 10_000)
    return true
  }
  const { save } = await import('@tauri-apps/plugin-dialog')
  const path = await save({ defaultPath: fileName })
  if (!path) {
    return false
  }
  const data = bytesToBase64(new Uint8Array(await blob.arrayBuffer()))
  await invoke('save_file', { path, dataBase64: data })
  return true
}
