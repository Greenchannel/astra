import { create } from 'zustand'
import { createId } from '../../utils/id.js'
import * as db from '../chat/db.js'
import type { MemoryItem, MemorySource } from './types.js'

/** 记忆总量上限；超过后不再自动新增（手动仍可添加） */
export const MAX_MEMORY_ITEMS = 200

type MemoryState = {
  items: MemoryItem[]
  loaded: boolean
}

export const useMemory = create<MemoryState>(() => ({ items: [], loaded: false }))

const sortItems = (items: MemoryItem[]): MemoryItem[] =>
  [...items].sort((a, b) => {
    if (a.source !== b.source) {
      return a.source === 'manual' ? -1 : 1
    }
    return b.updatedAt - a.updatedAt
  })

const commit = (items: MemoryItem[]) => {
  useMemory.setState({ items: sortItems(items) })
}

const report = db.reportStorageError('memory')

export const initMemory = async (): Promise<void> => {
  if (useMemory.getState().loaded) {
    return
  }
  try {
    const items = await db.loadMemories()
    useMemory.setState({ items: sortItems(items), loaded: true })
  } catch (error) {
    report(error)
    useMemory.setState({ loaded: true })
  }
}

export const normalizeMemory = (content: string) =>
  content.replace(/\s+/g, ' ').trim().toLowerCase()

const hasDuplicate = (items: MemoryItem[], content: string) => {
  const normalized = normalizeMemory(content)
  return items.some((item) => normalizeMemory(item.content) === normalized)
}

export const addMemory = (
  content: string,
  source: MemorySource = 'manual',
  sessionId: string | null = null
): MemoryItem | null => {
  const trimmed = content.trim()
  if (!trimmed) {
    return null
  }
  const items = useMemory.getState().items
  if (source === 'auto' && items.length >= MAX_MEMORY_ITEMS) {
    return null
  }
  if (hasDuplicate(items, trimmed)) {
    return null
  }
  const now = Date.now()
  const item: MemoryItem = {
    id: createId(),
    content: trimmed,
    source,
    enabled: true,
    createdAt: now,
    updatedAt: now,
    sessionId,
  }
  commit([...items, item])
  void db.putMemory(item).catch(report)
  return item
}

export const updateMemory = (id: string, patch: Partial<Pick<MemoryItem, 'content' | 'enabled'>>) => {
  const items = useMemory.getState().items
  const current = items.find((item) => item.id === id)
  if (!current) {
    return
  }
  if (patch.content !== undefined && !patch.content.trim()) {
    return
  }
  const next: MemoryItem = {
    ...current,
    ...patch,
    ...(patch.content !== undefined ? { content: patch.content.trim() } : {}),
    updatedAt: Date.now(),
  }
  commit(items.map((item) => (item.id === id ? next : item)))
  void db.putMemory(next).catch(report)
}

export const removeMemory = (id: string) => {
  commit(useMemory.getState().items.filter((item) => item.id !== id))
  void db.deleteMemory(id).catch(report)
}

export const clearMemory = () => {
  commit([])
  void db.clearMemories().catch(report)
}

export const replaceMemoryItems = (items: MemoryItem[]) => {
  commit(items)
  void db.replaceMemories(items).catch(report)
}

export const getEnabledMemories = (): MemoryItem[] =>
  useMemory.getState().items.filter((item) => item.enabled)
