import { useMemo, useState } from 'react'
import { useTranslate } from '../../i18n/index.js'
import { openExternal } from '../../services/platform.js'
import { detectModels, testModel } from '../../services/providers/detect.js'
import {
  PROVIDER_PRESETS,
  deepseekCapabilities,
  getPreset,
} from '../../services/providers/presets.js'
import {
  addProvider,
  removeProvider,
  setActiveProvider,
  updateProvider,
  useProviders,
} from '../../services/providers/store.js'
import type {
  FileCapability,
  ProviderCapabilities,
  ProviderConfig,
  ProviderKind,
  ProviderPreset,
} from '../../services/providers/types.js'
import { Button } from '../base/Button.js'
import { Modal } from '../base/Modal.js'
import { Select } from '../base/Select.js'
import { showToast } from '../base/toastState.js'
import styles from './Providers.module.css'

const KIND_OPTIONS: { value: ProviderKind; label: string }[] = [
  { value: 'deepseek', label: 'DeepSeek (Anthropic compatible)' },
  { value: 'openai', label: 'OpenAI compatible' },
  { value: 'anthropic', label: 'Anthropic' },
]

const FILE_OPTIONS: { value: FileCapability; label: string }[] = [
  { value: 'deepseek', label: 'DeepSeek Files API' },
  { value: 'inlineImages', label: 'Inline images' },
  { value: 'none', label: 'None' },
]

const CAPABILITY_KEYS = [
  ['thinking', 'providersCapabilityThinking'],
  ['search', 'providersCapabilitySearch'],
  ['title', 'providersCapabilityTitle'],
  ['speech', 'providersCapabilitySpeech'],
  ['images', 'providersCapabilityImages'],
  ['requiresApiKey', 'providersCapabilityRequiresKey'],
] as const

export const ProvidersSection = () => {
  const t = useTranslate()
  const providers = useProviders((state) => state.providers)
  const activeId = useProviders((state) => state.activeId)
  const [adding, setAdding] = useState(false)
  const [editingId, setEditingId] = useState<string | null>(null)
  const [deletingId, setDeletingId] = useState<string | null>(null)
  const editing = providers.find((provider) => provider.id === editingId) ?? null
  const deleting = providers.find((provider) => provider.id === deletingId) ?? null

  return (
    <div className={styles.section}>
      <div className={styles.header}>
        <div>
          <div className={styles.title}>{t('providersTitle')}</div>
          <div className={styles.description}>{t('providersDescription')}</div>
        </div>
        <Button variant="primary" size="m" onClick={() => setAdding(true)}>
          {t('providersAdd')}
        </Button>
      </div>

      {providers.length === 0 ? (
        <div className={styles.empty}>{t('providersEmpty')}</div>
      ) : (
        <div className={styles.list}>
          {providers.map((provider) => (
            <div
              key={provider.id}
              className={styles.card}
              data-active={provider.id === activeId || undefined}
            >
              <div className={styles.cardMain}>
                <div className={styles.cardTitleRow}>
                  <span className={styles.cardName}>{provider.name}</span>
                  {provider.id === activeId ? (
                    <span className={styles.badge}>{t('providersActive')}</span>
                  ) : null}
                  <span className={styles.kind}>{kindName(provider.kind)}</span>
                </div>
                <div className={styles.cardMeta}>{provider.baseUrl || t('providersNoBaseUrl')}</div>
                <div className={styles.cardMeta}>
                  {t('providersModel')}: {provider.chatModel ?? t('providersNoModel')}
                  {provider.capabilities.images && provider.imageModel
                    ? ` · ${t('providersImageModel')}: ${provider.imageModel}`
                    : ''}
                </div>
                {isDeepSeekOpenAI(provider) ? (
                  <div className={styles.warning}>
                    <span>{t('providersDeepSeekOpenAIOpenAIWarning')}</span>
                    <button
                      type="button"
                      className={styles.warningAction}
                      onClick={() => {
                        updateProvider(provider.id, {
                          kind: 'deepseek',
                          baseUrl: 'https://api.deepseek.com',
                          chatModel: provider.chatModel?.startsWith('deepseek')
                            ? provider.chatModel
                            : 'deepseek-flash',
                          capabilities: { ...deepseekCapabilities },
                        })
                      }}
                    >
                      {t('providersConvertToDeepSeek')}
                    </button>
                  </div>
                ) : null}
                {provider.kind === 'deepseek' && provider.chatModel !== 'deepseek-flash' ? (
                  <div className={styles.warning}>
                    <span>{t('providersDeepSeekFlashHint')}</span>
                    <button
                      type="button"
                      className={styles.warningAction}
                      onClick={() => updateProvider(provider.id, { chatModel: 'deepseek-flash' })}
                    >
                      {t('providersUseDeepSeekFlash')}
                    </button>
                  </div>
                ) : null}
              </div>
              <div className={styles.cardActions}>
                <Button
                  variant="outlined"
                  size="s"
                  disabled={provider.id === activeId}
                  onClick={() => setActiveProvider(provider.id)}
                >
                  {t('providersUse')}
                </Button>
                <Button variant="outlined" size="s" onClick={() => setEditingId(provider.id)}>
                  {t('edit')}
                </Button>
                <Button variant="dangerOutlined" size="s" onClick={() => setDeletingId(provider.id)}>
                  {t('delete')}
                </Button>
              </div>
            </div>
          ))}
        </div>
      )}

      {adding ? (
        <AddProviderModal
          onClose={() => setAdding(false)}
          onAdded={(id) => {
            setAdding(false)
            setEditingId(id)
          }}
        />
      ) : null}
      {editing ? <ProviderEditor provider={editing} onClose={() => setEditingId(null)} /> : null}
      {deleting ? (
        <Modal
          title={t('providersDeleteTitle')}
          onClose={() => setDeletingId(null)}
          footer={
            <>
              <Button variant="outlined" size="m" onClick={() => setDeletingId(null)}>
                {t('cancel')}
              </Button>
              <Button
                variant="danger"
                size="m"
                onClick={() => {
                  removeProvider(deleting.id)
                  setDeletingId(null)
                }}
              >
                {t('delete')}
              </Button>
            </>
          }
        >
          {t('providersDeleteDescription', { name: deleting.name })}
        </Modal>
      ) : null}
    </div>
  )
}

const isDeepSeekOpenAI = (provider: ProviderConfig) =>
  provider.kind === 'openai' && /deepseek\.com/i.test(provider.baseUrl)

const kindName = (kind: ProviderKind) => {
  if (kind === 'deepseek') {
    return 'DeepSeek'
  }
  if (kind === 'anthropic') {
    return 'Anthropic'
  }
  return 'OpenAI compatible'
}

const AddProviderModal = ({
  onClose,
  onAdded,
}: {
  onClose: () => void
  onAdded: (id: string) => void
}) => {
  const t = useTranslate()
  const add = (preset: ProviderPreset) => {
    const id = addProvider(preset)
    onAdded(id)
  }
  return (
    <Modal
      title={t('providersChoosePreset')}
      onClose={onClose}
      className={styles.presetModal}
      footer={
        <Button variant="outlined" size="m" onClick={onClose}>
          {t('cancel')}
        </Button>
      }
    >
      <div className={styles.presetGrid}>
        {PROVIDER_PRESETS.map((preset) => (
          <button
            key={preset.id}
            type="button"
            className={styles.preset}
            onClick={() => add(preset)}
          >
            <span className={styles.presetName}>{preset.name}</span>
            <span className={styles.presetKind}>
              {preset.kind === 'openai' ? 'OpenAI compatible' : kindName(preset.kind)}
            </span>
          </button>
        ))}
      </div>
    </Modal>
  )
}

type Draft = {
  name: string
  kind: ProviderKind
  baseUrl: string
  apiKey: string
  chatModel: string
  imageModel: string
  imageBaseUrl: string
  capabilities: ProviderCapabilities
}

const toDraft = (provider: ProviderConfig): Draft => ({
  name: provider.name,
  kind: provider.kind,
  baseUrl: provider.baseUrl,
  apiKey: provider.apiKey,
  chatModel: provider.chatModel ?? '',
  imageModel: provider.imageModel ?? '',
  imageBaseUrl: provider.imageBaseUrl ?? '',
  capabilities: { ...provider.capabilities },
})

const ProviderEditor = ({
  provider,
  onClose,
}: {
  provider: ProviderConfig
  onClose: () => void
}) => {
  const t = useTranslate()
  const [draft, setDraft] = useState<Draft>(() => toDraft(provider))
  const [detecting, setDetecting] = useState(false)
  const [testing, setTesting] = useState(false)
  const models = useProviders(
    (state) => state.providers.find((item) => item.id === provider.id)?.models ?? provider.models
  )
  const chatModels = useMemo(
    () => models.filter((model) => model.kind === 'chat'),
    [models]
  )
  const imageModels = useMemo(() => models.filter((model) => model.kind === 'image'), [models])
  const preset = provider.presetId ? getPreset(provider.presetId) : undefined

  const patch = (value: Partial<Draft>) => setDraft((current) => ({ ...current, ...value }))
  const patchCapability = (key: Exclude<keyof ProviderCapabilities, 'files'>, value: boolean) =>
    setDraft((current) => ({
      ...current,
      capabilities: { ...current.capabilities, [key]: value },
    }))
  const setFiles = (files: FileCapability) =>
    setDraft((current) => ({
      ...current,
      capabilities: { ...current.capabilities, files },
    }))

  const runDetect = async () => {
    setDetecting(true)
    try {
      const detected = await detectModels({
        ...provider,
        kind: draft.kind,
        baseUrl: draft.baseUrl,
        apiKey: draft.apiKey,
      })
      const nextChat =
        draft.chatModel || detected.find((model) => model.kind === 'chat')?.id || ''
      const nextImage =
        draft.imageModel || detected.find((model) => model.kind === 'image')?.id || ''
      updateProvider(provider.id, {
        models: detected,
        detectedAt: Date.now(),
        chatModel: nextChat || null,
        imageModel: nextImage || null,
      })
      setDraft((current) => ({
        ...current,
        chatModel: nextChat,
        imageModel: nextImage,
      }))
      showToast(t('providersDetected', { count: detected.length }))
    } catch (error) {
      showToast({
        key: 'providersDetectFailed',
        params: { message: error instanceof Error ? error.message : String(error) },
        type: 'error',
      })
    } finally {
      setDetecting(false)
    }
  }

  const runTest = async () => {
    if (!draft.chatModel) {
      return
    }
    setTesting(true)
    try {
      const reply = await testModel({
        ...provider,
        kind: draft.kind,
        baseUrl: draft.baseUrl,
        apiKey: draft.apiKey,
        chatModel: draft.chatModel,
      })
      showToast(t('providersTestOk', { reply: reply.slice(0, 60) }))
    } catch (error) {
      showToast({
        key: 'providersTestFailed',
        params: { message: error instanceof Error ? error.message : String(error) },
        type: 'error',
      })
    } finally {
      setTesting(false)
    }
  }

  const save = () => {
    // 按协议收敛能力，避免在 OpenAI 兼容供应商上勾选只有 DeepSeek 原生协议才支持的能力
    const capabilities: ProviderCapabilities = {
      ...draft.capabilities,
      search: draft.kind === 'deepseek' ? draft.capabilities.search : false,
      title: draft.kind === 'deepseek' ? draft.capabilities.title : false,
      speech: draft.kind === 'deepseek' ? draft.capabilities.speech : false,
      thinking: draft.kind === 'openai' ? false : draft.capabilities.thinking,
      images: draft.kind === 'anthropic' ? false : draft.capabilities.images,
      files:
        draft.kind === 'deepseek'
          ? 'deepseek'
          : draft.capabilities.files === 'none'
            ? 'none'
            : 'inlineImages',
    }
    updateProvider(provider.id, {
      name: draft.name.trim() || provider.name,
      kind: draft.kind,
      baseUrl: draft.baseUrl.trim(),
      apiKey: draft.apiKey.trim(),
      chatModel: draft.chatModel.trim() || null,
      imageModel: draft.imageModel.trim() || null,
      imageBaseUrl: draft.imageBaseUrl.trim() || null,
      capabilities,
    })
    onClose()
  }

  const capabilityDisabled = (key: Exclude<keyof ProviderCapabilities, 'files'>) => {
    if (key === 'search' || key === 'title' || key === 'speech') {
      return draft.kind !== 'deepseek'
    }
    if (key === 'thinking') {
      return draft.kind === 'openai'
    }
    if (key === 'images') {
      return draft.kind === 'anthropic'
    }
    return false
  }

  return (
    <Modal
      title={t('providersEditTitle', { name: provider.name })}
      onClose={onClose}
      className={styles.editorModal}
      footer={
        <>
          <Button variant="outlined" size="m" onClick={onClose}>
            {t('cancel')}
          </Button>
          <Button variant="primary" size="m" onClick={save}>
            {t('save')}
          </Button>
        </>
      }
    >
      <div className={styles.form}>
        <label className={styles.field}>
          <span>{t('providersName')}</span>
          <input value={draft.name} onChange={(event) => patch({ name: event.target.value })} />
        </label>
        <label className={styles.field}>
          <span>{t('providersKind')}</span>
          <Select
            value={draft.kind}
            options={KIND_OPTIONS}
            onChange={(kind) => patch({ kind })}
            ariaLabel={t('providersKind')}
          />
        </label>
        <label className={styles.field}>
          <span>{t('providersBaseUrl')}</span>
          <input
            value={draft.baseUrl}
            placeholder="https://api.example.com/v1"
            autoCapitalize="off"
            spellCheck={false}
            onChange={(event) => patch({ baseUrl: event.target.value })}
          />
          <span className={styles.hint}>{t('providersBaseUrlHint')}</span>
        </label>
        {draft.capabilities.requiresApiKey || draft.apiKey ? (
          <label className={styles.field}>
            <span>{t('providersApiKey')}</span>
            <input
              type="password"
              value={draft.apiKey}
              placeholder={t('apiKeyPlaceholder')}
              autoCapitalize="off"
              autoComplete="off"
              spellCheck={false}
              onChange={(event) => patch({ apiKey: event.target.value })}
            />
          </label>
        ) : null}
        {preset?.docsUrl ? (
          <div className={styles.docs}>
            <button
              type="button"
              className={styles.docsButton}
              onClick={() => void openExternal(preset.docsUrl ?? '')}
            >
              {t('providersGetKey')}
            </button>
          </div>
        ) : null}

        <label className={styles.field}>
          <span>{t('providersChatModel')}</span>
          <input
            list={`chat-models-${provider.id}`}
            value={draft.chatModel}
            placeholder="model-id"
            autoCapitalize="off"
            spellCheck={false}
            onChange={(event) => patch({ chatModel: event.target.value })}
          />
          <datalist id={`chat-models-${provider.id}`}>
            {chatModels.map((model) => (
              <option key={model.id} value={model.id}>
                {model.displayName ?? model.id}
              </option>
            ))}
          </datalist>
        </label>

        <div className={styles.sectionHeading}>{t('providersImageSection')}</div>
        <div className={styles.modelRow}>
          <label className={styles.field}>
            <span>{t('providersImageModel')}</span>
            <input
              list={`image-models-${provider.id}`}
              value={draft.imageModel}
              placeholder="image-model-id"
              autoCapitalize="off"
              spellCheck={false}
              onChange={(event) => patch({ imageModel: event.target.value })}
            />
            <datalist id={`image-models-${provider.id}`}>
              {imageModels.map((model) => (
                <option key={model.id} value={model.id}>
                  {model.displayName ?? model.id}
                </option>
              ))}
            </datalist>
          </label>
          <label className={styles.field}>
            <span>{t('providersImageBaseUrl')}</span>
            <input
              value={draft.imageBaseUrl}
              placeholder={draft.baseUrl || 'https://api.example.com/v1'}
              autoCapitalize="off"
              spellCheck={false}
              onChange={(event) => patch({ imageBaseUrl: event.target.value })}
            />
            <span className={styles.hint}>{t('providersImageBaseUrlHint')}</span>
          </label>
        </div>

        <div className={styles.detectRow}>
          <Button variant="outlined" size="m" disabled={detecting} onClick={() => void runDetect()}>
            {t(detecting ? 'providersDetecting' : 'providersDetect')}
          </Button>
          <Button
            variant="outlined"
            size="m"
            disabled={testing || !draft.chatModel}
            onClick={() => void runTest()}
          >
            {t(testing ? 'providersTesting' : 'providersTest')}
          </Button>
        </div>

        <div className={styles.capabilities}>
          {CAPABILITY_KEYS.map(([key, label]) => (
            <label key={key} className={styles.checkbox} data-disabled={capabilityDisabled(key) || undefined}>
              <input
                type="checkbox"
                checked={draft.capabilities[key]}
                disabled={capabilityDisabled(key)}
                onChange={(event) => patchCapability(key, event.target.checked)}
              />
              <span>{t(label)}</span>
            </label>
          ))}
        </div>
        <span className={styles.hint}>{t('providersCapabilitiesHint')}</span>
        <label className={styles.field}>
          <span>{t('providersFiles')}</span>
          <Select
            value={draft.capabilities.files}
            options={FILE_OPTIONS}
            onChange={setFiles}
            ariaLabel={t('providersFiles')}
          />
        </label>
        {draft.kind === 'deepseek' && draft.chatModel !== 'deepseek-flash' ? (
          <div className={styles.warning}>
            <span>{t('providersDeepSeekFlashHint')}</span>
            <button
              type="button"
              className={styles.warningAction}
              onClick={() => patch({ chatModel: 'deepseek-flash' })}
            >
              {t('providersUseDeepSeekFlash')}
            </button>
          </div>
        ) : null}
      </div>
    </Modal>
  )
}
