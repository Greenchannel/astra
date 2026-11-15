import { invoke } from '@tauri-apps/api/core'
import { listen, type UnlistenFn } from '@tauri-apps/api/event'
import { createId } from '../../utils/id.js'

/**
 * 统一 HTTP 传输层。
 * - 浏览器：原生 fetch，受供应商 CORS 限制。
 * - Tauri：Rust reqwest（`http_request` / `http_stream`），绕过 WebView CORS 并支持真正的 SSE 流式输出。
 * 只在应用壳里调用 Rust；普通 web 构建仍然走 fetch。
 */

export type HttpInit = {
  method?: string
  headers?: Record<string, string>
  body?: BodyInit | null
  signal?: AbortSignal
  timeoutMs?: number
}

export type ResponseLike = {
  ok: boolean
  status: number
  statusText: string
  headers: { get(name: string): string | null }
  body: ReadableStream<Uint8Array> | null
  bytes(): Promise<Uint8Array>
  text(): Promise<string>
  json(): Promise<unknown>
}

type TauriHttpRequest = {
  url: string
  method: string
  headers: Record<string, string>
  bodyBase64: string | null
  timeoutMs: number | null
}

type TauriHttpResponse = {
  status: number
  statusText: string
  headers: Record<string, string>
  bodyBase64: string
}

type TauriStreamEvent = {
  id: string
  kind: 'start' | 'chunk' | 'end' | 'error'
  status?: number
  statusText?: string
  headers?: Record<string, string>
  data?: string
  message?: string
}

const STREAM_EVENT = 'astra-http-stream'

export const isTauri = (): boolean =>
  typeof window !== 'undefined' && '__TAURI_INTERNALS__' in window

const textEncoder = new TextEncoder()
const textDecoder = new TextDecoder()

const toBase64 = (bytes: Uint8Array): string => {
  let binary = ''
  const chunk = 0x8000
  for (let index = 0; index < bytes.length; index += chunk) {
    binary += String.fromCharCode(...bytes.subarray(index, index + chunk))
  }
  return btoa(binary)
}

const fromBase64 = (value: string): Uint8Array => {
  const binary = atob(value)
  const bytes = new Uint8Array(binary.length)
  for (let index = 0; index < binary.length; index++) {
    bytes[index] = binary.charCodeAt(index)
  }
  return bytes
}

const bodyToBytes = async (body: BodyInit | null | undefined): Promise<Uint8Array | null> => {
  if (body === null || body === undefined) {
    return null
  }
  if (typeof body === 'string') {
    return textEncoder.encode(body)
  }
  if (body instanceof Blob) {
    return new Uint8Array(await body.arrayBuffer())
  }
  if (body instanceof ArrayBuffer) {
    return new Uint8Array(body)
  }
  if (ArrayBuffer.isView(body)) {
    return new Uint8Array(body.buffer, body.byteOffset, body.byteLength)
  }
  throw new Error('Unsupported request body for native transport')
}

const headersOf = (headers?: Record<string, string> | Headers): Record<string, string> => {
  if (!headers) {
    return {}
  }
  if (headers instanceof Headers) {
    return Object.fromEntries(headers.entries())
  }
  return { ...headers }
}

const headerGetter = (headers: Record<string, string>) => ({
  get: (name: string) =>
    Object.entries(headers).find(([key]) => key.toLowerCase() === name.toLowerCase())?.[1] ??
    null,
})

const wrapResponse = (response: Response): ResponseLike => ({
  ok: response.ok,
  status: response.status,
  statusText: response.statusText,
  headers: response.headers,
  body: response.body,
  bytes: async () => new Uint8Array(await response.arrayBuffer()),
  text: () => response.text(),
  json: () => response.json(),
})

const readStream = async (body: ReadableStream<Uint8Array> | null): Promise<Uint8Array> => {
  if (!body) {
    return new Uint8Array()
  }
  const reader = body.getReader()
  const chunks: Uint8Array[] = []
  for (;;) {
    const { done, value } = await reader.read()
    if (done) {
      break
    }
    chunks.push(value)
  }
  return concatBytes(chunks)
}

const timedSignal = (signal: AbortSignal | undefined, timeoutMs: number | undefined) => {
  if (!timeoutMs) {
    return { signal, clear: () => {} }
  }
  const controller = new AbortController()
  const timer = window.setTimeout(() => controller.abort(new Error('Request timeout')), timeoutMs)
  const forward = () => controller.abort(signal?.reason)
  if (signal?.aborted) {
    controller.abort(signal.reason)
  } else {
    signal?.addEventListener('abort', forward, { once: true })
  }
  return {
    signal: controller.signal,
    clear: () => {
      window.clearTimeout(timer)
      signal?.removeEventListener('abort', forward)
    },
  }
}

const webFetch = async (url: string, init: HttpInit): Promise<ResponseLike> => {
  const timed = timedSignal(init.signal, init.timeoutMs)
  try {
    const response = await fetch(url, {
      method: init.method ?? 'GET',
      headers: init.headers,
      body: init.body,
      signal: timed.signal,
    })
    return wrapResponse(response)
  } finally {
    timed.clear()
  }
}

/** 普通请求：浏览器用 fetch；Tauri 走 Rust（FormData 仍在 WebView 内发，兼容文件上传）。 */
export const httpRequest = async (url: string, init: HttpInit = {}): Promise<ResponseLike> => {
  if (!isTauri() || init.body instanceof FormData) {
    return webFetch(url, init)
  }
  const bodyBase64 = await bodyToBytes(init.body).then((bytes) =>
    bytes ? toBase64(bytes) : null
  )
  const result = await invoke<TauriHttpResponse>('http_request', {
    request: {
      url,
      method: init.method ?? 'GET',
      headers: headersOf(init.headers),
      bodyBase64,
      timeoutMs: init.timeoutMs ?? null,
    } satisfies TauriHttpRequest,
  })
  const bytes = fromBase64(result.bodyBase64)
  return {
    ok: result.status >= 200 && result.status < 300,
    status: result.status,
    statusText: result.statusText,
    headers: headerGetter(result.headers),
    body: null,
    bytes: async () => bytes,
    text: async () => textDecoder.decode(bytes),
    json: async () => JSON.parse(textDecoder.decode(bytes)) as unknown,
  }
}

/**
 * 流式请求：Tauri 侧等待 Rust 的 `start` 事件后返回，后续 chunk 通过事件推入 ReadableStream。
 * 中止信号会同时取消 Rust 侧请求。
 */
export const httpStream = async (url: string, init: HttpInit = {}): Promise<ResponseLike> => {
  if (!isTauri()) {
    return webFetch(url, init)
  }
  const id = createId()
  const headers = headersOf(init.headers)
  const bodyBase64 = await bodyToBytes(init.body).then((bytes) =>
    bytes ? toBase64(bytes) : null
  )
  const pendingChunks: Uint8Array[] = []
  let controller: ReadableStreamDefaultController<Uint8Array> | null = null
  let status = 0
  let statusText = ''
  let responseHeaders: Record<string, string> = {}
  let settleStart: ((value: void | PromiseLike<void>) => void) | null = null
  let failStart: ((reason: unknown) => void) | null = null
  let finished = false
  let ended = false
  let streamError: unknown = null

  const cleanup = () => {
    if (finished) {
      return
    }
    finished = true
    init.signal?.removeEventListener('abort', onAbort)
    unlisten?.()
  }

  const fail = (reason: unknown) => {
    if (controller) {
      try {
        controller.error(reason)
      } catch {
        // 流已关闭
      }
    } else {
      streamError = reason
      failStart?.(reason)
    }
    cleanup()
  }

  const onAbort = () => {
    void invoke('http_stream_abort', { requestId: id }).catch(() => {})
    fail(init.signal?.reason ?? new Error('Aborted'))
  }

  const handler = (event: { payload: TauriStreamEvent }) => {
    const payload = event.payload
    if (payload.id !== id) {
      return
    }
    switch (payload.kind) {
      case 'start':
        status = payload.status ?? 0
        statusText = payload.statusText ?? ''
        responseHeaders = payload.headers ?? {}
        settleStart?.()
        break
      case 'chunk': {
        if (!payload.data) {
          return
        }
        const bytes = fromBase64(payload.data)
        if (controller) {
          controller.enqueue(bytes)
        } else {
          pendingChunks.push(bytes)
        }
        break
      }
      case 'end':
        ended = true
        controller?.close()
        cleanup()
        break
      case 'error':
        fail(new Error(payload.message ?? 'Stream failed'))
        break
    }
  }

  let unlisten: UnlistenFn | undefined
  unlisten = await listen<TauriStreamEvent>(STREAM_EVENT, handler)
  init.signal?.addEventListener('abort', onAbort, { once: true })

  const startPromise = new Promise<void>((resolve, reject) => {
    settleStart = resolve
    failStart = reject
  })

  try {
    await invoke('http_stream', {
      requestId: id,
      request: {
        url,
        method: init.method ?? 'GET',
        headers,
        bodyBase64,
        timeoutMs: init.timeoutMs ?? null,
      } satisfies TauriHttpRequest,
    })
    await startPromise
  } catch (error) {
    cleanup()
    throw error
  }

  const body = new ReadableStream<Uint8Array>({
    start(streamController) {
      controller = streamController
      for (const chunk of pendingChunks.splice(0)) {
        streamController.enqueue(chunk)
      }
      if (streamError !== null) {
        streamController.error(streamError)
      } else if (ended) {
        streamController.close()
      }
    },
    cancel() {
      void invoke('http_stream_abort', { requestId: id }).catch(() => {})
      cleanup()
    },
  })

  return {
    ok: status >= 200 && status < 300,
    status,
    statusText,
    headers: headerGetter(responseHeaders),
    body,
    bytes: () => readStream(body),
    text: async () => textDecoder.decode(await readStream(body)),
    json: async () => JSON.parse(textDecoder.decode(await readStream(body))) as unknown,
  }
}

const concatBytes = (chunks: Uint8Array[]): Uint8Array => {
  const length = chunks.reduce((sum, chunk) => sum + chunk.byteLength, 0)
  const merged = new Uint8Array(length)
  let offset = 0
  for (const chunk of chunks) {
    merged.set(chunk, offset)
    offset += chunk.byteLength
  }
  return merged
}

/** 下载二进制内容（生图返回 URL 时使用） */
export const httpBytes = async (url: string, init: HttpInit = {}): Promise<Uint8Array> => {
  const response = await httpRequest(url, init)
  if (!response.ok) {
    throw new Error(`HTTP ${response.status} ${response.statusText}`)
  }
  return response.bytes()
}
