import { ApiError, joinUrl, request, requestStream } from '../../api/client.js'
import { readServerSentEvents } from '../../api/sse.js'
import type { MessageStreamEvent, MessageUsage, StopReason } from '../../api/types.js'
import { getContextRounds, getReplyText } from '../../chat/reply.js'
import type { UserMessage } from '../../chat/types.js'
import type { ProviderConfig } from '../types.js'
import type { ChatAdapter } from './types.js'
import {
  isRecord,
  loadImageData,
  type ChatInput,
  type CompletionInput,
} from './shared.js'

type AnthropicBlock =
  | { type: 'text'; text: string }
  | {
      type: 'image'
      source: { type: 'base64'; media_type: string; data: string }
    }

type AnthropicMessage = { role: 'user' | 'assistant'; content: AnthropicBlock[] }

const headers = (provider: ProviderConfig): Record<string, string> => ({
  'x-api-key': provider.apiKey,
  'anthropic-version': '2023-06-01',
  // 浏览器直连 Anthropic 时必须显式声明；原生请求带上也无害
  'anthropic-dangerous-direct-browser-access': 'true',
  'Content-Type': 'application/json',
})

const userBlocks = async (user: UserMessage): Promise<AnthropicBlock[]> => {
  const blocks: AnthropicBlock[] = []
  for (const file of user.files) {
    const image = await loadImageData(file)
    if (image) {
      blocks.push({
        type: 'image',
        source: { type: 'base64', media_type: image.mimeType, data: image.data },
      })
    }
  }
  if (user.content.trim()) {
    blocks.push({ type: 'text', text: user.content })
  }
  return blocks
}

const toMessages = async (input: ChatInput): Promise<AnthropicMessage[]> => {
  const messages: AnthropicMessage[] = []
  for (const [user, reply] of getContextRounds(input.history)) {
    const blocks = await userBlocks(user)
    if (blocks.length === 0) {
      continue
    }
    messages.push({ role: 'user', content: blocks })
    const text = getReplyText(reply)
    if (text.trim()) {
      messages.push({ role: 'assistant', content: [{ type: 'text', text }] })
    }
  }
  const question = await userBlocks(input.question)
  if (question.length > 0) {
    messages.push({ role: 'user', content: question })
  }
  if (input.prefix?.prefix) {
    const text = getReplyText(input.prefix)
    if (text.trim()) {
      messages.push({ role: 'assistant', content: [{ type: 'text', text }] })
    }
  }
  return messages
}

const toUsage = (value: unknown): MessageUsage | undefined => {
  if (!isRecord(value)) {
    return undefined
  }
  const number = (key: string) =>
    typeof value[key] === 'number' ? (value[key] as number) : 0
  const usage: MessageUsage = {
    input_tokens: number('input_tokens'),
    cache_creation_input_tokens: number('cache_creation_input_tokens'),
    cache_read_input_tokens: number('cache_read_input_tokens'),
    output_tokens: number('output_tokens'),
  }
  return usage
}

const toStopReason = (value: unknown): StopReason => {
  switch (value) {
    case 'max_tokens':
      return 'max_tokens'
    case 'tool_use':
      return 'tool_use'
    case 'refusal':
      return 'refusal'
    default:
      return 'end_turn'
  }
}

const readEvent = (payload: unknown): MessageStreamEvent | null => {
  if (!isRecord(payload) || typeof payload.type !== 'string') {
    return null
  }
  switch (payload.type) {
    case 'message_start': {
      const message = isRecord(payload.message) ? payload.message : null
      if (!message) {
        return null
      }
      return {
        type: 'message_start',
        message: {
          id: typeof message.id === 'string' ? message.id : 'anthropic',
          model: typeof message.model === 'string' ? message.model : '',
          ...(toUsage(message.usage) ? { usage: toUsage(message.usage) } : {}),
        },
      }
    }
    case 'content_block_start': {
      if (typeof payload.index !== 'number' || !isRecord(payload.content_block)) {
        return null
      }
      const block = payload.content_block
      if (block.type === 'text') {
        return {
          type: 'content_block_start',
          index: payload.index,
          content_block: { type: 'text', text: typeof block.text === 'string' ? block.text : '' },
        }
      }
      if (block.type === 'thinking') {
        return {
          type: 'content_block_start',
          index: payload.index,
          content_block: {
            type: 'thinking',
            thinking: typeof block.thinking === 'string' ? block.thinking : '',
            signature: typeof block.signature === 'string' ? block.signature : '',
          },
        }
      }
      return null
    }
    case 'content_block_delta': {
      if (typeof payload.index !== 'number' || !isRecord(payload.delta)) {
        return null
      }
      const delta = payload.delta
      if (delta.type === 'text_delta' && typeof delta.text === 'string') {
        return {
          type: 'content_block_delta',
          index: payload.index,
          delta: { type: 'text_delta', text: delta.text },
        }
      }
      if (delta.type === 'thinking_delta' && typeof delta.thinking === 'string') {
        return {
          type: 'content_block_delta',
          index: payload.index,
          delta: { type: 'thinking_delta', thinking: delta.thinking },
        }
      }
      if (delta.type === 'signature_delta' && typeof delta.signature === 'string') {
        return {
          type: 'content_block_delta',
          index: payload.index,
          delta: { type: 'signature_delta', signature: delta.signature },
        }
      }
      return null
    }
    case 'content_block_stop':
      return typeof payload.index === 'number'
        ? { type: 'content_block_stop', index: payload.index }
        : null
    case 'message_delta': {
      if (!isRecord(payload.delta)) {
        return null
      }
      return {
        type: 'message_delta',
        delta: {
          stop_reason: toStopReason(payload.delta.stop_reason),
          stop_sequence: null,
        },
        ...(toUsage(payload.usage) ? { usage: toUsage(payload.usage) } : {}),
      }
    }
    case 'message_stop':
      return { type: 'message_stop' }
    default:
      return null
  }
}

const buildBody = async (
  provider: ProviderConfig,
  input: ChatInput,
  stream: boolean
): Promise<Record<string, unknown>> => ({
  model: provider.chatModel ?? '',
  max_tokens: 8192,
  ...(input.system.trim() ? { system: input.system } : {}),
  messages: await toMessages(input),
  ...(stream ? { stream: true } : {}),
  // 不在关闭时发送 thinking:disabled，部分 Anthropic 兼容网关不接受该值
  ...(input.thinking ? { thinking: { type: 'enabled', budget_tokens: 2048 } } : {}),
})

export const anthropicAdapter: ChatAdapter = {
  async *stream(provider, input, signal): AsyncGenerator<MessageStreamEvent> {
    const response = await requestStream(joinUrl(provider.baseUrl, 'messages'), {
      method: 'POST',
      headers: { ...headers(provider), Accept: 'text/event-stream' },
      body: JSON.stringify(await buildBody(provider, input, true)),
      signal,
    })
    const contentType = response.headers.get('Content-Type') ?? ''
    if (!response.body || !contentType.includes('text/event-stream')) {
      const text = await response.text().catch(() => '')
      throw new ApiError('protocol', text || 'Response is not an event stream')
    }
    for await (const { data } of readServerSentEvents(response.body, signal)) {
      let payload: unknown
      try {
        payload = JSON.parse(data)
      } catch {
        continue
      }
      if (isRecord(payload) && payload.type === 'error') {
        const error = isRecord(payload.error) ? payload.error : null
        const message =
          error && typeof error.message === 'string' ? error.message : 'Stream error'
        throw new ApiError('stream', message)
      }
      const event = readEvent(payload)
      if (!event) {
        continue
      }
      yield event
      if (event.type === 'message_stop') {
        return
      }
    }
    throw new ApiError('interrupted', '')
  },

  async complete(provider, input: CompletionInput): Promise<string> {
    const messages: AnthropicMessage[] = input.messages.flatMap((message) =>
      message.content.trim()
        ? [
            {
              role: message.role === 'assistant' ? ('assistant' as const) : ('user' as const),
              content: [{ type: 'text' as const, text: message.content }],
            },
          ]
        : []
    )
    const response = await request(joinUrl(provider.baseUrl, 'messages'), {
      method: 'POST',
      headers: headers(provider),
      body: JSON.stringify({
        model: provider.chatModel ?? '',
        max_tokens: input.maxTokens ?? 1024,
        ...(input.system.trim() ? { system: input.system } : {}),
        messages,
        stream: false,
      }),
      timeoutMs: 120_000,
    })
    const body = await response.json()
    if (!isRecord(body) || !Array.isArray(body.content)) {
      throw new ApiError('protocol', 'Empty completion')
    }
    const text = body.content
      .flatMap((block) =>
        isRecord(block) && block.type === 'text' && typeof block.text === 'string'
          ? [block.text]
          : []
      )
      .join('')
    if (!text) {
      throw new ApiError('protocol', 'Empty completion')
    }
    return text
  },
}
