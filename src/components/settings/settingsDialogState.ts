import { create } from 'zustand'
import { getChatProvider } from '../../services/providers/store.js'

/** 设置弹窗的分组：通用设置 / 供应商 / 记忆 / 数据管理 */
export type SettingsSection = 'general' | 'providers' | 'memory' | 'data'

/** 设置弹窗：侧边栏底部、没有可用供应商时的操作与 401 提示都可以打开；section 为打开时选中的分组 */
export const useSettingsDialog = create(() => ({
  open: false,
  section: 'general' as SettingsSection,
}))

export const openSettings = (section: SettingsSection) =>
  useSettingsDialog.setState({ open: true, section })

export const closeSettings = () => useSettingsDialog.setState({ open: false })

/** 没有可用供应商（未配置或未选模型）时打开供应商设置，返回是否已经可用 */
export const ensureProvider = () => {
  if (getChatProvider()) {
    return true
  }
  openSettings('providers')
  return false
}
