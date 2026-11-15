import { ApiError, joinUrl, request, streamMessage } from '../../api/client.js'
import type { CreateMessageRequest, MessageStreamEvent } from '../../api/types.js'
import { toRequestMessages } from '../../chat/reply.js'
import type { ProviderConfig } from '../types.js'
import type { ChatAdapter } from './types.js'
import { isRecord, type ChatInput, type CompletionInput } from './shared.js'

/** 阅读链接始终开启，智能搜索开关控制是否另行声明搜索工具（含边想边搜）。 */
const serverTools = (search: boolean): CreateMessageRequest['tools'] => {
  const tools: CreateMessageRequest['tools'] = [
    { type: 'deepseek_read_url', name: 'deepseek_read_url' },
  ]
  if (search) {
    tools.push({ type: 'deepseek_web_search', name: 'deepseek_web_search' })
  }
  return tools
}

const buildBody = (
  provider: ProviderConfig,
  input: ChatInput,
  title: boolean
): CreateMessageRequest => ({
  model: provider.chatModel ?? '',
  system: input.system,
  messages: toRequestMessages(
    input.history,
    input.question,
    input.prefix,
    input.thinking,
    input.latestReminder
  ),
  thinking: { type: input.thinking ? 'enabled' : 'disabled' },
  safety_check: { level: 'high' },
  tools: serverTools(input.search && provider.capabilities.search),
  ...(title ? { title: { enabled: true } } : {}),
})

const readContentText = (body: unknown): string => {
  if (!isRecord(body) || !Array.isArray(body.content)) {
    return ''
  }
  return body.content
    .flatMap((block) => (isRecord(block) && block.type === 'text' && typeof block.text === 'string' ? [block.text] : []))
    .join('')
}

export const deepseekAdapter: ChatAdapter = {
  async *stream(provider, input, signal): AsyncGenerator<MessageStreamEvent> {
    const body = buildBody(provider, input, input.title)
    yield* streamMessage(
      { baseUrl: provider.baseUrl, apiKey: provider.apiKey },
      body,
      signal
    )
  },

  async complete(provider, input: CompletionInput): Promise<string> {
    const response = await request(joinUrl(provider.baseUrl, 'anthropic/v1/messages'), {
      method: 'POST',
      headers: {
        'x-api-key': provider.apiKey,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        model: provider.chatModel ?? '',
        system: input.system,
        messages: input.messages.map((message) => ({
          role: message.role === 'system' ? 'user' : message.role,
          content: message.content,
        })),
        thinking: { type: 'disabled' },
        safety_check: { level: 'high' },
        tools: [],
        max_tokens: input.maxTokens ?? 1024,
        stream: false,
      }),
      timeoutMs: 120_000,
    })
    const body = await response.json()
    const text = readContentText(body)
    if (!text) {
      throw new ApiError('protocol', 'Empty completion')
    }
    return text
  },
}
