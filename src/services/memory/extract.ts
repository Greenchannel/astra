import { getAdapter } from '../providers/adapters/index.js'
import type { ProviderConfig } from '../providers/types.js'
import { useSettings } from '../settings.js'
import { addMemory, normalizeMemory, useMemory } from './store.js'

/** 同一会话两次自动提取的最小间隔 */
const THROTTLE_MS = 60_000
/** 单次最多新增条目 */
const MAX_NEW_ITEMS = 8
/** 单条记忆最大长度 */
const MAX_CONTENT_LENGTH = 300

const lastRuns = new Map<string, number>()

const parseItems = (text: string): string[] => {
  const start = text.indexOf('[')
  const end = text.lastIndexOf(']')
  if (start < 0 || end <= start) {
    return []
  }
  try {
    const parsed: unknown = JSON.parse(text.slice(start, end + 1))
    if (!Array.isArray(parsed)) {
      return []
    }
    return parsed.flatMap((item) => {
      if (typeof item === 'string') {
        return [item]
      }
      if (
        typeof item === 'object' &&
        item !== null &&
        'content' in item &&
        typeof item.content === 'string'
      ) {
        return [item.content]
      }
      return []
    })
  } catch {
    return []
  }
}

/**
 * 一次回复结束后异步提取长期记忆；失败、限流、超时都静默忽略，不影响聊天。
 * 只取纯文本对话，不读取附件内容。
 */
export const scheduleMemoryExtraction = (
  provider: ProviderConfig,
  sessionId: string,
  conversation: string
) => {
  if (!useSettings.getState().memoryAutoExtract || !provider.chatModel) {
    return
  }
  if (conversation.trim().length < 40) {
    return
  }
  const now = Date.now()
  if (now - (lastRuns.get(sessionId) ?? 0) < THROTTLE_MS) {
    return
  }
  lastRuns.set(sessionId, now)

  const existing = useMemory
    .getState()
    .items.slice(0, 80)
    .map((item) => `- ${item.content}`)
    .join('\n')

  const prompt = [
    'Extract durable facts about the user from the conversation below.',
    'Rules:',
    '- Only include stable preferences, identity details, ongoing projects, or long-term goals.',
    '- Do not include transient requests, greetings, or facts about the assistant.',
    '- Keep each fact short (one sentence), in the language the user used.',
    '- Do not repeat anything already in Existing memories.',
    '- Return ONLY a JSON array of strings. No markdown, no explanations.',
    '',
    'Existing memories:',
    existing || '(none)',
    '',
    'Conversation:',
    conversation.slice(-6000),
  ].join('\n')

  void (async () => {
    const text = await getAdapter(provider.kind).complete(provider, {
      system:
        'You are a precise long-term memory extractor. Output only valid JSON as instructed.',
      messages: [{ role: 'user', content: prompt }],
      maxTokens: 700,
    })
    const existingSet = new Set(
      useMemory.getState().items.map((item) => normalizeMemory(item.content))
    )
    let added = 0
    for (const raw of parseItems(text)) {
      if (added >= MAX_NEW_ITEMS) {
        break
      }
      const content = raw.trim().slice(0, MAX_CONTENT_LENGTH)
      if (!content) {
        continue
      }
      const normalized = normalizeMemory(content)
      if (existingSet.has(normalized)) {
        continue
      }
      if (addMemory(content, 'auto', sessionId)) {
        existingSet.add(normalized)
        added += 1
      }
    }
  })().catch(() => {
    // 自动记忆是尽力而为，不向界面报错
  })
}
