/** 供应商协议类型 */
export type ProviderKind = 'deepseek' | 'openai' | 'anthropic'

/** 附件支持方式：DeepSeek Files API / 只支持内联图片 / 不支持 */
export type FileCapability = 'deepseek' | 'inlineImages' | 'none'

export type ProviderCapabilities = {
  /** 是否支持深度思考 */
  thinking: boolean
  /** 是否支持服务端联网搜索 */
  search: boolean
  /** 是否支持服务端自动生成标题 */
  title: boolean
  /** 是否支持 DeepSeek 语音接口 */
  speech: boolean
  /** 附件能力 */
  files: FileCapability
  /** 是否支持 OpenAI 兼容生图 */
  images: boolean
  /** 是否必须填写 API Key（本地 Ollama / LM Studio 可为 false） */
  requiresApiKey: boolean
}

export type ProviderModelKind = 'chat' | 'image' | 'unknown'

export type ProviderModel = {
  id: string
  displayName?: string
  kind: ProviderModelKind
}

export type ProviderConfig = {
  id: string
  name: string
  kind: ProviderKind
  /** API 根路径（不含 /chat/completions 等具体端点） */
  baseUrl: string
  apiKey: string
  models: ProviderModel[]
  chatModel: string | null
  imageModel: string | null
  /** 生图单独地址；为空时使用 baseUrl */
  imageBaseUrl: string | null
  capabilities: ProviderCapabilities
  /** 获取 API Key 的文档链接 */
  docsUrl?: string
  /** 来自哪个内置预设 */
  presetId?: string
  detectedAt?: number
  createdAt: number
  updatedAt: number
}

export type ProviderPreset = {
  id: string
  name: string
  kind: ProviderKind
  baseUrl: string
  capabilities: ProviderCapabilities
  docsUrl?: string
}

/** 生图结果（已下载为 Blob，存入本地 files 表后以 GeneratedImage 引用） */
export type GeneratedImage = {
  /** 本地 files 表主键 */
  id: string
  mimeType: string
  prompt: string
  model: string
  revisedPrompt?: string
  width?: number
  height?: number
  createdAt: number
}

export type ChatProvider = ProviderConfig & { chatModel: string }
