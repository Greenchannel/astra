import { joinUrl, request } from '../api/client.js'
import { createLatestReminder } from '../chat/latestReminder.js'
import { useSettings } from '../settings.js'
import { getAdapter } from './adapters/index.js'
import type { ProviderConfig, ProviderKind, ProviderModel, ProviderModelKind } from './types.js'

const IMAGE_MODEL_PATTERN =
  /(dall-e|gpt-image|flux|stable-diffusion|sdxl|seedream|kolors|imagen|recraft|ideogram|qwen-image|wanx|kling|text-to-image|image-preview)/i

const NON_CHAT_PATTERN =
  /(embed|embedding|rerank|whisper|tts|speech|asr|transcri|moderation|ocr|audio)/i

export const classifyModel = (id: string): ProviderModelKind => {
  if (IMAGE_MODEL_PATTERN.test(id)) {
    return 'image'
  }
  if (NON_CHAT_PATTERN.test(id)) {
    return 'unknown'
  }
  return 'chat'
}

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === 'object' && value !== null

const readModels = (body: unknown): { models: ProviderModel[]; hasMore: boolean; lastId?: string } => {
  if (!isRecord(body)) {
    return { models: [], hasMore: false }
  }
  const raw = Array.isArray(body.data)
    ? body.data
    : Array.isArray(body.models)
      ? body.models
      : []
  const models: ProviderModel[] = []
  const seen = new Set<string>()
  for (const item of raw) {
    if (!isRecord(item)) {
      continue
    }
    const id =
      typeof item.id === 'string'
        ? item.id
        : typeof item.name === 'string'
          ? item.name
          : typeof item.model === 'string'
            ? item.model
            : null
    if (!id || seen.has(id)) {
      continue
    }
    seen.add(id)
    const displayName =
      typeof item.display_name === 'string'
        ? item.display_name
        : typeof item.displayName === 'string'
          ? item.displayName
          : typeof item.name === 'string'
            ? item.name
            : undefined
    const declaredKind =
      item.type === 'image' || item.model_type === 'image'
        ? 'image'
        : item.type === 'chat' || item.model_type === 'chat'
          ? 'chat'
          : undefined
    models.push({
      id,
      ...(displayName ? { displayName } : {}),
      kind: declaredKind ?? classifyModel(id),
    })
  }
  return {
    models,
    hasMore: body.has_more === true,
    ...(typeof body.last_id === 'string' ? { lastId: body.last_id } : {}),
  }
}

const authHeaders = (provider: ProviderConfig, kind: ProviderKind): Record<string, string> => {
  if (kind === 'anthropic') {
    return {
      'x-api-key': provider.apiKey,
      'anthropic-version': '2023-06-01',
      'anthropic-dangerous-direct-browser-access': 'true',
    }
  }
  return provider.apiKey ? { Authorization: `Bearer ${provider.apiKey}` } : {}
}

/** 拉取供应商模型列表；Anthropic 支持分页，最多取 5 页 */
export const detectModels = async (
  provider: ProviderConfig,
  signal?: AbortSignal
): Promise<ProviderModel[]> => {
  const models: ProviderModel[] = []
  const seen = new Set<string>()
  let afterId: string | undefined
  for (let page = 0; page < 5; page++) {
    const query = afterId ? `?after_id=${encodeURIComponent(afterId)}` : ''
    const response = await request(joinUrl(provider.baseUrl, `models${query}`), {
      method: 'GET',
      headers: authHeaders(provider, provider.kind),
      signal,
      timeoutMs: 20_000,
    })
    const parsed = readModels(await response.json())
    for (const model of parsed.models) {
      if (!seen.has(model.id)) {
        seen.add(model.id)
        models.push(model)
      }
    }
    if (!parsed.hasMore || !parsed.lastId) {
      break
    }
    afterId = parsed.lastId
  }
  const rank: Record<ProviderModelKind, number> = { chat: 0, image: 1, unknown: 2 }
  return models.sort(
    (a, b) => rank[a.kind] - rank[b.kind] || a.id.localeCompare(b.id)
  )
}

/** 发一次极小的非流式请求，验证模型真的可用 */
export const testModel = async (provider: ProviderConfig): Promise<string> => {
  const text = await getAdapter(provider.kind).complete(provider, {
    system: 'You are a connectivity test.',
    messages: [{ role: 'user', content: 'Reply with the single word OK.' }],
    maxTokens: 16,
  })
  return text.trim()
}

/** 非 DeepSeek 供应商无法使用 latest_reminder，需要把当前上下文写进 system */
export const providerDefaultSystemPrompt = (kind: ProviderKind): string => {
  if (kind === 'deepseek') {
    return '该助手为DeepSeek，由深度求索公司创造。'
  }
  if (kind === 'openai') {
    return 'You are a helpful assistant.'
  }
  return ''
}

/** 自定义 system prompt > 供应商默认；末尾追加记忆块与（非 DeepSeek）当前上下文 */
export const buildSystemPrompt = (provider: ProviderConfig, memoryBlock: string): string => {
  const custom = useSettings.getState().systemPrompt?.trim()
  const base = custom || providerDefaultSystemPrompt(provider.kind)
  const parts = [base, memoryBlock]
  if (provider.kind !== 'deepseek') {
    const reminder = createLatestReminder(useSettings.getState())
    if (reminder) {
      parts.push(`Current context: ${reminder}.`)
    }
  }
  return parts.filter((part) => part.trim()).join('\n\n')
}
