import type { ProviderCapabilities, ProviderPreset } from './types.js'

const openAICompatible: ProviderCapabilities = {
  thinking: false,
  search: false,
  title: false,
  speech: false,
  files: 'inlineImages',
  images: false,
  requiresApiKey: true,
}

const withCapabilities = (
  preset: Omit<ProviderPreset, 'capabilities'> & { capabilities?: Partial<ProviderCapabilities> }
): ProviderPreset => ({
  ...preset,
  capabilities: { ...openAICompatible, ...preset.capabilities },
})

export const deepseekCapabilities: ProviderCapabilities = {
  thinking: true,
  search: true,
  title: true,
  speech: true,
  files: 'deepseek',
  images: false,
  requiresApiKey: true,
}

/**
 * 内置供应商预设：只包含连接信息，不包含任何 API Key。
 * 模型列表不内置，添加后点「检测模型」实时获取，避免模型名过期。
 */
export const PROVIDER_PRESETS: ProviderPreset[] = [
  {
    id: 'deepseek',
    name: 'DeepSeek',
    kind: 'deepseek',
    baseUrl: 'https://api.deepseek.com',
    capabilities: deepseekCapabilities,
    docsUrl: 'https://platform.deepseek.com/api_keys',
  },
  withCapabilities({
    id: 'openai',
    name: 'OpenAI',
    kind: 'openai',
    baseUrl: 'https://api.openai.com/v1',
    capabilities: { images: true },
    docsUrl: 'https://platform.openai.com/api-keys',
  }),
  withCapabilities({
    id: 'anthropic',
    name: 'Anthropic',
    kind: 'anthropic',
    baseUrl: 'https://api.anthropic.com/v1',
    capabilities: { thinking: true },
    docsUrl: 'https://console.anthropic.com/settings/keys',
  }),
  withCapabilities({
    id: 'openrouter',
    name: 'OpenRouter',
    kind: 'openai',
    baseUrl: 'https://openrouter.ai/api/v1',
    docsUrl: 'https://openrouter.ai/keys',
  }),
  withCapabilities({
    id: 'gemini',
    name: 'Google Gemini',
    kind: 'openai',
    baseUrl: 'https://generativelanguage.googleapis.com/v1beta/openai',
    docsUrl: 'https://aistudio.google.com/apikey',
  }),
  withCapabilities({
    id: 'xai',
    name: 'xAI',
    kind: 'openai',
    baseUrl: 'https://api.x.ai/v1',
    docsUrl: 'https://console.x.ai/',
  }),
  withCapabilities({
    id: 'groq',
    name: 'Groq',
    kind: 'openai',
    baseUrl: 'https://api.groq.com/openai/v1',
    docsUrl: 'https://console.groq.com/keys',
  }),
  withCapabilities({
    id: 'mistral',
    name: 'Mistral',
    kind: 'openai',
    baseUrl: 'https://api.mistral.ai/v1',
    docsUrl: 'https://console.mistral.ai/api-keys/',
  }),
  withCapabilities({
    id: 'together',
    name: 'Together',
    kind: 'openai',
    baseUrl: 'https://api.together.xyz/v1',
    docsUrl: 'https://api.together.ai/settings/api-keys',
  }),
  withCapabilities({
    id: 'siliconflow',
    name: '硅基流动 SiliconFlow',
    kind: 'openai',
    baseUrl: 'https://api.siliconflow.cn/v1',
    capabilities: { images: true },
    docsUrl: 'https://cloud.siliconflow.cn/account/ak',
  }),
  withCapabilities({
    id: 'moonshot',
    name: 'Moonshot Kimi',
    kind: 'openai',
    baseUrl: 'https://api.moonshot.cn/v1',
    docsUrl: 'https://platform.moonshot.cn/console/api-keys',
  }),
  withCapabilities({
    id: 'zhipu',
    name: '智谱 BigModel',
    kind: 'openai',
    baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
    docsUrl: 'https://bigmodel.cn/usercenter/apikeys',
  }),
  withCapabilities({
    id: 'dashscope',
    name: '阿里云百炼 DashScope',
    kind: 'openai',
    baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
    docsUrl: 'https://bailian.console.aliyun.com/',
  }),
  withCapabilities({
    id: 'ark',
    name: '火山方舟 Ark',
    kind: 'openai',
    baseUrl: 'https://ark.cn-beijing.volces.com/api/v3',
    docsUrl: 'https://console.volcengine.com/ark',
  }),
  withCapabilities({
    id: 'minimax',
    name: 'MiniMax',
    kind: 'openai',
    baseUrl: 'https://api.minimax.chat/v1',
    docsUrl: 'https://platform.minimaxi.com/',
  }),
  withCapabilities({
    id: 'qianfan',
    name: '百度千帆',
    kind: 'openai',
    baseUrl: 'https://qianfan.baidubce.com/v2',
    docsUrl: 'https://console.bce.baidu.com/qianfan/',
  }),
  withCapabilities({
    id: 'hunyuan',
    name: '腾讯混元',
    kind: 'openai',
    baseUrl: 'https://api.hunyuan.cloud.tencent.com/v1',
    docsUrl: 'https://console.cloud.tencent.com/hunyuan',
  }),
  withCapabilities({
    id: 'ollama',
    name: 'Ollama（本地）',
    kind: 'openai',
    baseUrl: 'http://localhost:11434/v1',
    capabilities: { requiresApiKey: false },
    docsUrl: 'https://ollama.com/',
  }),
  withCapabilities({
    id: 'lmstudio',
    name: 'LM Studio（本地）',
    kind: 'openai',
    baseUrl: 'http://localhost:1234/v1',
    capabilities: { requiresApiKey: false },
    docsUrl: 'https://lmstudio.ai/',
  }),
  {
    id: 'custom',
    name: '自定义 OpenAI 兼容',
    kind: 'openai',
    baseUrl: '',
    capabilities: { ...openAICompatible },
  },
]

export const getPreset = (id: string): ProviderPreset | undefined =>
  PROVIDER_PRESETS.find((preset) => preset.id === id)
