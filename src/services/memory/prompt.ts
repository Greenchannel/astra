import { getEnabledMemories } from './store.js'
import type { MemoryItem } from './types.js'

/** 注入 system prompt 的记忆字符预算；超出后按排序截断 */
export const MEMORY_CHAR_BUDGET = 2000

export const buildMemoryBlock = (items: MemoryItem[]): string => {
  const lines: string[] = []
  let used = 0
  for (const item of items) {
    if (!item.enabled) {
      continue
    }
    const line = `- ${item.content.trim()}`
    if (!line.trim() || used + line.length > MEMORY_CHAR_BUDGET) {
      continue
    }
    lines.push(line)
    used += line.length + 1
  }
  if (lines.length === 0) {
    return ''
  }
  return [
    '## Long-term memory about the user',
    'Facts saved from earlier conversations. Use them when relevant, and do not mention this section explicitly.',
    ...lines,
  ].join('\n')
}

export const currentMemoryBlock = (): string => buildMemoryBlock(getEnabledMemories())
