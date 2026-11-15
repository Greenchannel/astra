import type { ProviderKind } from '../types.js'
import { anthropicAdapter } from './anthropic.js'
import { deepseekAdapter } from './deepseek.js'
import { openAIAdapter } from './openai.js'
import type { ChatAdapter } from './types.js'

export const getAdapter = (kind: ProviderKind): ChatAdapter => {
  if (kind === 'deepseek') {
    return deepseekAdapter
  }
  if (kind === 'anthropic') {
    return anthropicAdapter
  }
  return openAIAdapter
}
