import { joinUrl, request } from '../api/client.js'
import { httpBytes } from '../api/transport.js'
import type { ProviderConfig } from '../providers/types.js'

export type ImageGenOptions = {
  prompt: string
  model: string
  size?: string
  count?: number
}

export type ImageGenResult = {
  blob: Blob
  mimeType: string
  revisedPrompt?: string
}

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === 'object' && value !== null

const fromBase64 = (value: string): Uint8Array => {
  const binary = atob(value)
  const bytes = new Uint8Array(binary.length)
  for (let index = 0; index < binary.length; index++) {
    bytes[index] = binary.charCodeAt(index)
  }
  return bytes
}

const detectMime = (bytes: Uint8Array): string => {
  if (bytes.length >= 8 && bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e) {
    return 'image/png'
  }
  if (bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) {
    return 'image/jpeg'
  }
  if (
    bytes.length >= 12 &&
    bytes[0] === 0x52 &&
    bytes[1] === 0x49 &&
    bytes[2] === 0x46 &&
    bytes[3] === 0x46 &&
    bytes[8] === 0x57 &&
    bytes[9] === 0x45 &&
    bytes[10] === 0x42 &&
    bytes[11] === 0x50
  ) {
    return 'image/webp'
  }
  if (bytes.length >= 3 && bytes[0] === 0x47 && bytes[1] === 0x49 && bytes[2] === 0x46) {
    return 'image/gif'
  }
  return 'image/png'
}

/**
 * 调用 OpenAI 兼容 /images/generations。
 * 同时兼容 b64_json 与 url 两种返回；url 会立即下载为 Blob，避免过期。
 */
export const generateImages = async (
  provider: ProviderConfig,
  options: ImageGenOptions,
  signal: AbortSignal
): Promise<ImageGenResult[]> => {
  const base = provider.imageBaseUrl?.trim() || provider.baseUrl
  const response = await request(joinUrl(base, 'images/generations'), {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${provider.apiKey}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      model: options.model,
      prompt: options.prompt,
      n: options.count ?? 1,
      ...(options.size ? { size: options.size } : {}),
    }),
    signal,
    timeoutMs: 300_000,
  })
  const body = await response.json()
  if (!isRecord(body) || !Array.isArray(body.data) || body.data.length === 0) {
    throw new Error('The provider returned no images')
  }
  const results: ImageGenResult[] = []
  for (const item of body.data) {
    if (!isRecord(item)) {
      continue
    }
    const revisedPrompt =
      typeof item.revised_prompt === 'string' ? item.revised_prompt : undefined
    if (typeof item.b64_json === 'string' && item.b64_json) {
      const bytes = fromBase64(item.b64_json)
      results.push({
        blob: new Blob([bytes.slice()], { type: detectMime(bytes) }),
        mimeType: detectMime(bytes),
        ...(revisedPrompt ? { revisedPrompt } : {}),
      })
      continue
    }
    if (typeof item.url === 'string' && item.url) {
      const bytes = await httpBytes(item.url, { signal, timeoutMs: 120_000 })
      results.push({
        blob: new Blob([bytes.slice()], { type: detectMime(bytes) }),
        mimeType: detectMime(bytes),
        ...(revisedPrompt ? { revisedPrompt } : {}),
      })
    }
  }
  if (results.length === 0) {
    throw new Error('The provider returned no usable images')
  }
  return results
}
