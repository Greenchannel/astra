export type MemorySource = 'manual' | 'auto'

/** 全局长期记忆条目，存 IndexedDB 的 memories 表 */
export type MemoryItem = {
  id: string
  content: string
  source: MemorySource
  enabled: boolean
  createdAt: number
  updatedAt: number
  /** 自动提取来源的会话；手动添加为空 */
  sessionId?: string | null
}
