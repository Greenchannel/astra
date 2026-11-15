import type { MessageStreamEvent } from '../../api/types.js'
import type { ProviderConfig } from '../types.js'
import type { ChatInput, CompletionInput } from './shared.js'

export type ChatAdapter = {
  /** 流式对话，产出与现有回复管线兼容的 Anthropic 风格事件 */
  stream(
    provider: ProviderConfig,
    input: ChatInput,
    signal: AbortSignal
  ): AsyncGenerator<MessageStreamEvent>
  /** 非流式完成，用于标题/记忆提取/模型测试 */
  complete(provider: ProviderConfig, input: CompletionInput): Promise<string>
}
