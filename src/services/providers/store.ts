import { create } from 'zustand'
import { createId } from '../../utils/id.js'
import { deepseekCapabilities, getPreset } from './presets.js'
import type {
  ChatProvider,
  ProviderConfig,
  ProviderModel,
  ProviderPreset,
} from './types.js'

const KEYS = {
  providers: 'chat-demo:providers',
  active: 'chat-demo:active-provider',
} as const

const LEGACY_API_KEY = 'chat-demo:api-key'

const read = (key: string) => {
  try {
    return localStorage.getItem(key)
  } catch {
    return null
  }
}

const write = (key: string, value: string | null) => {
  try {
    if (value === null) {
      localStorage.removeItem(key)
    } else {
      localStorage.setItem(key, value)
    }
  } catch {
    // 存储不可用时只在内存中生效
  }
}

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === 'object' && value !== null

const readModels = (value: unknown): ProviderModel[] => {
  if (!Array.isArray(value)) {
    return []
  }
  return value.flatMap((item) => {
    if (!isRecord(item) || typeof item.id !== 'string' || !item.id) {
      return []
    }
    const kind =
      item.kind === 'chat' || item.kind === 'image' || item.kind === 'unknown'
        ? item.kind
        : 'unknown'
    return [
      {
        id: item.id,
        ...(typeof item.displayName === 'string' ? { displayName: item.displayName } : {}),
        kind,
      },
    ]
  })
}

/**
 * 官方 DeepSeek 的 OpenAI 兼容地址不支持思考开关/联网/自动标题。
 * 读到这种配置时自动转成原生协议，避免用户误用后功能全部失效。
 */
const migrateDeepSeek = (provider: ProviderConfig): ProviderConfig => {
  if (!/api\.deepseek\.com/i.test(provider.baseUrl)) {
    return provider
  }
  if (provider.kind === 'deepseek') {
    return provider.baseUrl.replace(/\/+$/, '') === 'https://api.deepseek.com'
      ? provider
      : { ...provider, baseUrl: 'https://api.deepseek.com' }
  }
  if (provider.kind === 'openai') {
    return {
      ...provider,
      kind: 'deepseek',
      baseUrl: 'https://api.deepseek.com',
      chatModel: 'deepseek-flash',
      presetId: 'deepseek',
      docsUrl: provider.docsUrl ?? 'https://platform.deepseek.com/api_keys',
      capabilities: {
        ...deepseekCapabilities,
        images: provider.capabilities.images,
      },
    }
  }
  return provider
}

const readProvider = (value: unknown): ProviderConfig | null => {
  if (!isRecord(value) || typeof value.id !== 'string' || typeof value.kind !== 'string') {
    return null
  }
  if (value.kind !== 'deepseek' && value.kind !== 'openai' && value.kind !== 'anthropic') {
    return null
  }
  const capabilities = isRecord(value.capabilities) ? value.capabilities : {}
  const preset = typeof value.presetId === 'string' ? getPreset(value.presetId) : undefined
  const base = preset?.capabilities ?? {
    thinking: false,
    search: false,
    title: false,
    speech: false,
    files: 'inlineImages' as const,
    images: false,
    requiresApiKey: true,
  }
  const flag = (key: 'thinking' | 'search' | 'title' | 'speech' | 'images' | 'requiresApiKey') =>
    typeof capabilities[key] === 'boolean' ? (capabilities[key] as boolean) : base[key]
  const provider: ProviderConfig = {
    id: value.id,
    name: typeof value.name === 'string' && value.name ? value.name : 'Provider',
    kind: value.kind,
    baseUrl: typeof value.baseUrl === 'string' ? value.baseUrl : '',
    apiKey: typeof value.apiKey === 'string' ? value.apiKey : '',
    models: readModels(value.models),
    chatModel: typeof value.chatModel === 'string' ? value.chatModel : null,
    imageModel: typeof value.imageModel === 'string' ? value.imageModel : null,
    imageBaseUrl: typeof value.imageBaseUrl === 'string' ? value.imageBaseUrl : null,
    capabilities: {
      thinking: flag('thinking'),
      search: flag('search'),
      title: flag('title'),
      speech: flag('speech'),
      files:
        capabilities.files === 'deepseek' ||
        capabilities.files === 'inlineImages' ||
        capabilities.files === 'none'
          ? capabilities.files
          : base.files,
      images: flag('images'),
      requiresApiKey: flag('requiresApiKey'),
    },
    ...(typeof value.docsUrl === 'string' ? { docsUrl: value.docsUrl } : {}),
    ...(typeof value.presetId === 'string' ? { presetId: value.presetId } : {}),
    ...(typeof value.detectedAt === 'number' ? { detectedAt: value.detectedAt } : {}),
    createdAt: typeof value.createdAt === 'number' ? value.createdAt : Date.now(),
    updatedAt: typeof value.updatedAt === 'number' ? value.updatedAt : Date.now(),
  }
  return migrateDeepSeek(provider)
}

export const createProviderFromPreset = (
  preset: ProviderPreset,
  apiKey = ''
): ProviderConfig => {
  const now = Date.now()
  return {
    id: createId(),
    name: preset.name,
    kind: preset.kind,
    baseUrl: preset.baseUrl,
    apiKey,
    models: [],
    // DeepSeek 预设保留 demo 的默认模型，首次使用无需先检测也能直接对话
    chatModel: preset.id === 'deepseek' ? 'deepseek-flash' : null,
    imageModel: null,
    imageBaseUrl: null,
    capabilities: { ...preset.capabilities },
    ...(preset.docsUrl ? { docsUrl: preset.docsUrl } : {}),
    presetId: preset.id,
    createdAt: now,
    updatedAt: now,
  }
}

const initialProviders = (): ProviderConfig[] => {
  const raw = read(KEYS.providers)
  if (raw) {
    try {
      const parsed: unknown = JSON.parse(raw)
      if (Array.isArray(parsed)) {
        const providers = parsed
          .map(readProvider)
          .filter((provider): provider is ProviderConfig => provider !== null)
        // 已经有保存过（哪怕是空列表），不再用旧 key 自动补一个。
        return providers
      }
    } catch {
      // 忽略损坏的存储，继续走迁移
    }
  }
  const legacyKey = read(LEGACY_API_KEY)
  const preset = getPreset('deepseek')
  if (legacyKey && preset) {
    return [createProviderFromPreset(preset, legacyKey)]
  }
  return []
}

const initialActiveId = (providers: ProviderConfig[]): string | null => {
  const saved = read(KEYS.active)
  if (saved && providers.some((provider) => provider.id === saved)) {
    return saved
  }
  return providers[0]?.id ?? null
}

type ProvidersState = {
  providers: ProviderConfig[]
  activeId: string | null
}

const initial = initialProviders()

export const useProviders = create<ProvidersState>(() => ({
  providers: initial,
  activeId: initialActiveId(initial),
}))

const persistProviders = (providers: ProviderConfig[]) => {
  write(KEYS.providers, JSON.stringify(providers))
}

const persistActive = (activeId: string | null) => {
  write(KEYS.active, activeId)
}

// 启动时把旧配置（如 DeepSeek 的 OpenAI 兼容地址）迁移结果写回，避免每次加载重复迁移
persistProviders(initial)
persistActive(initialActiveId(initial))

const setProviders = (
  update: (providers: ProviderConfig[]) => ProviderConfig[],
  nextActiveId?: string | null
) => {
  const providers = update(useProviders.getState().providers)
  const activeId =
    nextActiveId !== undefined
      ? nextActiveId
      : providers.some((provider) => provider.id === useProviders.getState().activeId)
        ? useProviders.getState().activeId
        : (providers[0]?.id ?? null)
  useProviders.setState({ providers, activeId })
  persistProviders(providers)
  persistActive(activeId)
}

export const addProvider = (preset: ProviderPreset, apiKey = ''): string => {
  const provider = createProviderFromPreset(preset, apiKey)
  setProviders((providers) => [...providers, provider], provider.id)
  return provider.id
}

export const updateProvider = (id: string, patch: Partial<ProviderConfig>) => {
  setProviders((providers) =>
    providers.map((provider) =>
      provider.id === id
        ? migrateDeepSeek({ ...provider, ...patch, updatedAt: Date.now() })
        : provider
    )
  )
}

export const removeProvider = (id: string) => {
  const state = useProviders.getState()
  const providers = state.providers.filter((provider) => provider.id !== id)
  const activeId = state.activeId === id ? (providers[0]?.id ?? null) : state.activeId
  setProviders(() => providers, activeId)
}

export const setActiveProvider = (id: string) => {
  if (useProviders.getState().providers.some((provider) => provider.id === id)) {
    useProviders.setState({ activeId: id })
    persistActive(id)
  }
}

export const setProviderModels = (
  id: string,
  models: ProviderModel[],
  detectedAt = Date.now()
) => {
  updateProvider(id, { models, detectedAt })
}

export const selectChatModel = (providerId: string, model: string) => {
  updateProvider(providerId, { chatModel: model })
  setActiveProvider(providerId)
}

export const selectImageModel = (providerId: string, model: string) => {
  updateProvider(providerId, { imageModel: model })
}

export const getProviderById = (id: string | null | undefined): ProviderConfig | null => {
  if (!id) {
    return null
  }
  return useProviders.getState().providers.find((provider) => provider.id === id) ?? null
}

export const getActiveProvider = (): ProviderConfig | null => {
  const { activeId, providers } = useProviders.getState()
  return providers.find((provider) => provider.id === activeId) ?? null
}

const hasUsableKey = (provider: ProviderConfig) =>
  !provider.capabilities.requiresApiKey || provider.apiKey.trim() !== ''

/** 当前可用于聊天的供应商：已选模型且（需要时）已填 Key */
export const getChatProvider = (): ChatProvider | null => {
  const provider = getActiveProvider()
  if (!provider || !provider.chatModel || !hasUsableKey(provider)) {
    return null
  }
  return provider as ChatProvider
}

/** 当前可用于语音（DeepSeek 工具接口）的供应商 */
export const getSpeechProvider = (): ProviderConfig | null => {
  const provider = getActiveProvider()
  return provider && provider.capabilities.speech && hasUsableKey(provider) ? provider : null
}

/** 可用于生图的供应商：能力开启且有图片模型 */
export const getImageProvider = (): ProviderConfig | null => {
  const { providers, activeId } = useProviders.getState()
  const active = providers.find((provider) => provider.id === activeId)
  if (active?.capabilities.images && active.imageModel && hasUsableKey(active)) {
    return active
  }
  return (
    providers.find(
      (provider) => provider.capabilities.images && provider.imageModel && hasUsableKey(provider)
    ) ?? null
  )
}

export const hasAnyProvider = () => useProviders.getState().providers.length > 0

export const providerLabel = (provider: ProviderConfig) =>
  provider.chatModel ? `${provider.name} · ${provider.chatModel}` : provider.name
