import { getContextRounds, getReplyText } from '../../chat/reply.js'
import type { AssistantMessage, FileAttachment, Message, UserMessage } from '../../chat/types.js'
import { getCachedBlob } from '../../chat/blobCache.js'
import * as db from '../../chat/db.js'

export type ChatInput = {
  history: Message[]
  question: UserMessage
  prefix?: AssistantMessage
  thinking: boolean
  search: boolean
  system: string
  title: boolean
  /** DeepSeek 专用：每轮系统信息快照 */
  latestReminder?: string
}

export type SimpleMessage = {
  role: 'system' | 'user' | 'assistant'
  content: string
}

export type CompletionInput = {
  system: string
  messages: SimpleMessage[]
  maxTokens?: number
}

export type ImageData = {
  mimeType: string
  data: string
}

const bytesToBase64 = (bytes: Uint8Array): string => {
  let binary = ''
  const chunk = 0x8000
  for (let index = 0; index < bytes.length; index += chunk) {
    binary += String.fromCharCode(...bytes.subarray(index, index + chunk))
  }
  return btoa(binary)
}

export const blobToBase64 = async (blob: Blob): Promise<string> =>
  bytesToBase64(new Uint8Array(await blob.arrayBuffer()))

export const loadImageData = async (file: FileAttachment): Promise<ImageData | null> => {
  if (!file.isImage) {
    return null
  }
  const blob = getCachedBlob(file.id) ?? (await db.loadFile(file.id))
  if (!blob) {
    return null
  }
  return {
    mimeType: file.mimeType || blob.type || 'image/png',
    data: await blobToBase64(blob),
  }
}

export const toDataUrl = (image: ImageData) => `data:${image.mimeType};base64,${image.data}`

/** 会话文本（不含附件内容），用于自动记忆提取等内部请求 */
export const conversationText = (history: Message[], question?: UserMessage): string => {
  const lines: string[] = []
  for (const [user, reply] of getContextRounds(history)) {
    if (user.content.trim()) {
      lines.push(`User: ${user.content.trim()}`)
    }
    const text = getReplyText(reply).trim()
    if (text) {
      lines.push(`Assistant: ${text}`)
    }
  }
  if (question?.content.trim()) {
    lines.push(`User: ${question.content.trim()}`)
  }
  return lines.join('\n\n')
}

export const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === 'object' && value !== null

export const readString = (value: unknown): string | null =>
  typeof value === 'string' ? value : null
