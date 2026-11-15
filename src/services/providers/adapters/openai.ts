import { ApiError, joinUrl, request, requestStream } from '../../api/client.js'
import { readServerSentEvents } from '../../api/sse.js'
import type { MessageStreamEvent, MessageUsage, StopReason } from '../../api/types.js'
import { getContextRounds, getReplyText } from '../../chat/reply.js'
import type { UserMessage } from '../../chat/types.js'
import type { ChatAdapter } from './types.js'
import {
  isRecord,
  loadImageData,
  toDataUrl,
  type ChatInput,
  type CompletionInput,
} from './shared.js'

type OpenAIPart =
  | { type: 'text'; text: string }
  | { type: 'image_url'; image_url: { url: string } }

type OpenAIMessage = {
  role: 'system' | 'user' | 'assistant'
  content: string | OpenAIPart[]
}

const userContent = async (user: UserMessage): Promise<string | OpenAIPart[]> => {
  const parts: OpenAIPart[] = []
  for (const file of user.files) {
    const image = await loadImageData(file)
    if (image) {
      parts.push({ type: 'image_url', image_url: { url: toDataUrl(image) } })
    }
  }
  if (parts.length === 0) {
    return user.content
  }
  return [
    ...(user.content ? [{ type: 'text' as const, text: user.content }] : []),
    ...parts,
  ]
}

const toMessages = async (input: ChatInput): Promise<OpenAIMessage[]> => {
  const messages: OpenAIMessage[] = []
  if (input.system.trim()) {
    messages.push({ role: 'system', content: input.system })
  }
  for (const [user, reply] of getContextRounds(input.history)) {
    const content = await userContent(user)
    if (typeof content === 'string' && !content.trim()) {
      continue
    }
    messages.push({ role: 'user', content })
    const text = getReplyText(reply)
    if (text.trim()) {
      messages.push({ role: 'assistant', content: text })
    }
  }
  const question = await userContent(input.question)
  if (typeof question !== 'string' || question.trim()) {
    messages.push({ role: 'user', content: question })
  }
  if (input.prefix?.prefix) {
    const text = getReplyText(input.prefix)
    if (text.trim()) {
      messages.push({ role: 'assistant', content: text })
    }
  }
  return messages
}

const toUsage = (value: unknown): MessageUsage | undefined => {
  if (!isRecord(value)) {
    return undefined
  }
  const prompt = typeof value.prompt_tokens === 'number' ? value.prompt_tokens : 0
  const completion = typeof value.completion_tokens === 'number' ? value.completion_tokens : 0
  const cached =
    isRecord(value.prompt_tokens_details) &&
    typeof value.prompt_tokens_details.cached_tokens === 'number'
      ? value.prompt_tokens_details.cached_tokens
      : 0
  if (prompt === 0 && completion === 0) {
    return undefined
  }
  return {
    input_tokens: Math.max(0, prompt - cached),
    cache_creation_input_tokens: 0,
    cache_read_input_tokens: cached,
    output_tokens: completion,
  }
}

const toStopReason = (value: unknown): StopReason => {
  switch (value) {
    case 'length':
      return 'max_tokens'
    case 'content_filter':
      return 'refusal'
    case 'tool_calls':
    case 'function_call':
      return 'tool_use'
    default:
      return 'end_turn'
  }
}

const readDelta = (value: unknown): Record<string, unknown> | null => {
  if (!isRecord(value) || !Array.isArray(value.choices) || value.choices.length === 0) {
    return null
  }
  const choice = value.choices[0]
  return isRecord(choice) ? choice : null
}

const readMessageText = (value: unknown): string => {
  if (!isRecord(value) || !Array.isArray(value.content)) {
    return ''
  }
  return value.content
    .flatMap((part) =>
      isRecord(part) && part.type === 'text' && typeof part.text === 'string' ? [part.text] : []
    )
    .join('')
}

export const openAIAdapter: ChatAdapter = {
  async *stream(provider, input, signal): AsyncGenerator<MessageStreamEvent> {
    const response = await requestStream(joinUrl(provider.baseUrl, 'chat/completions'), {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${provider.apiKey}`,
        'Content-Type': 'application/json',
        Accept: 'text/event-stream',
      },
      body: JSON.stringify({
        model: provider.chatModel ?? '',
        messages: await toMessages(input),
        stream: true,
      }),
      signal,
    })
    const contentType = response.headers.get('Content-Type') ?? ''
    if (!response.body || !contentType.includes('text/event-stream')) {
      const text = await response.text().catch(() => '')
      throw new ApiError('protocol', text || 'Response is not an event stream')
    }

    let started = false
    let thinkingOpen = false
    let textOpen = false
    let textEmitted = false
    let usage: MessageUsage | undefined
    let finished = false
    let finishReason: unknown

    const emitStart = function* (): Generator<MessageStreamEvent> {
      if (!started) {
        started = true
        yield {
          type: 'message_start',
          message: { id: 'openai', model: provider.chatModel ?? '', ...(usage ? { usage } : {}) },
        }
      }
    }

    for await (const { data } of readServerSentEvents(response.body, signal)) {
      if (data.trim() === '[DONE]') {
        finished = true
        break
      }
      let payload: unknown
      try {
        payload = JSON.parse(data)
      } catch {
        continue
      }
      if (isRecord(payload) && isRecord(payload.error)) {
        const message =
          typeof payload.error.message === 'string' ? payload.error.message : 'Stream error'
        throw new ApiError('stream', message)
      }
      if (!isRecord(payload)) {
        continue
      }
      const chunkUsage = toUsage(payload.usage)
      if (chunkUsage) {
        usage = chunkUsage
      }
      const choice = readDelta(payload)
      if (!choice) {
        continue
      }
      if (typeof choice.finish_reason === 'string') {
        finishReason = choice.finish_reason
      }
      if (isRecord(choice.delta)) {
        const reasoning =
          typeof choice.delta.reasoning_content === 'string'
            ? choice.delta.reasoning_content
            : typeof choice.delta.reasoning === 'string'
              ? choice.delta.reasoning
              : ''
        if (reasoning) {
          yield* emitStart()
          if (!thinkingOpen) {
            thinkingOpen = true
            yield {
              type: 'content_block_start',
              index: 0,
              content_block: { type: 'thinking', thinking: '', signature: '' },
            }
          }
          yield {
            type: 'content_block_delta',
            index: 0,
            delta: { type: 'thinking_delta', thinking: reasoning },
          }
        }
        if (typeof choice.delta.content === 'string' && choice.delta.content) {
          yield* emitStart()
          if (thinkingOpen) {
            thinkingOpen = false
            yield { type: 'content_block_stop', index: 0 }
          }
          if (!textOpen) {
            textOpen = true
            yield {
              type: 'content_block_start',
              index: 1,
              content_block: { type: 'text', text: '' },
            }
          }
          textEmitted = true
          yield {
            type: 'content_block_delta',
            index: 1,
            delta: { type: 'text_delta', text: choice.delta.content },
          }
        }
      }
      // 少数网关忽略 stream 参数，直接回完整 message
      if (!textEmitted && isRecord(choice.message)) {
        const full = readMessageText(choice.message)
        if (full) {
          yield* emitStart()
          if (!textOpen) {
            textOpen = true
            yield {
              type: 'content_block_start',
              index: 1,
              content_block: { type: 'text', text: '' },
            }
          }
          textEmitted = true
          yield {
            type: 'content_block_delta',
            index: 1,
            delta: { type: 'text_delta', text: full },
          }
        }
      }
    }

    if (!started) {
      yield* emitStart()
    }
    if (thinkingOpen) {
      yield { type: 'content_block_stop', index: 0 }
    }
    if (textOpen) {
      yield { type: 'content_block_stop', index: 1 }
    }
    if (!finished && finishReason === undefined) {
      throw new ApiError('interrupted', '')
    }
    yield {
      type: 'message_delta',
      delta: { stop_reason: toStopReason(finishReason), stop_sequence: null },
      ...(usage ? { usage } : {}),
    }
    yield { type: 'message_stop' }
  },

  async complete(provider, input: CompletionInput): Promise<string> {
    const messages: OpenAIMessage[] = [
      ...(input.system.trim() ? [{ role: 'system' as const, content: input.system }] : []),
      ...input.messages.map((message) => ({
        role: message.role === 'system' ? ('user' as const) : message.role,
        content: message.content,
      })),
    ]
    const response = await request(joinUrl(provider.baseUrl, 'chat/completions'), {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${provider.apiKey}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        model: provider.chatModel ?? '',
        messages,
        stream: false,
      }),
      timeoutMs: 120_000,
    })
    const body = await response.json()
    if (!isRecord(body) || !Array.isArray(body.choices) || body.choices.length === 0) {
      throw new ApiError('protocol', 'Empty completion')
    }
    const choice = body.choices[0]
    const message = isRecord(choice) && isRecord(choice.message) ? choice.message : null
    if (!message) {
      throw new ApiError('protocol', 'Empty completion')
    }
    if (typeof message.content === 'string' && message.content.trim()) {
      return message.content
    }
    const text = readMessageText(message)
    if (!text) {
      throw new ApiError('protocol', 'Empty completion')
    }
    return text
  },
}
