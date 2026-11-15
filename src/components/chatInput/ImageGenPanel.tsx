import { useState } from 'react'
import { useTranslate } from '../../i18n/index.js'
import { generateImage } from '../../services/chat/store.js'
import { getImageProvider, useProviders } from '../../services/providers/store.js'
import { Button } from '../base/Button.js'
import { Modal } from '../base/Modal.js'
import { Select } from '../base/Select.js'
import { showToast } from '../base/toastState.js'
import { openSettings } from '../settings/settingsDialogState.js'
import styles from './ImageGenPanel.module.css'

const SIZES = ['1024x1024', '1024x1536', '1536x1024', '512x512']
const COUNTS = [1, 2, 3, 4]

export const ImageGenPanel = ({
  sessionId,
  onClose,
}: {
  sessionId: string | null
  onClose: () => void
}) => {
  const t = useTranslate()
  const providers = useProviders((state) => state.providers)
  const imageProviders = providers.filter(
    (provider) =>
      provider.capabilities.images &&
      (!provider.capabilities.requiresApiKey || provider.apiKey.trim())
  )
  const preferred = getImageProvider()
  const [providerId, setProviderId] = useState(
    preferred?.id ?? imageProviders[0]?.id ?? ''
  )
  const provider = imageProviders.find((item) => item.id === providerId) ?? null
  const [model, setModel] = useState(provider?.imageModel ?? '')
  const [prompt, setPrompt] = useState('')
  const [size, setSize] = useState('1024x1024')
  const [count, setCount] = useState(1)
  const imageModels = provider?.models.filter((item) => item.kind === 'image') ?? []

  if (imageProviders.length === 0) {
    return (
      <Modal
        title={t('imageGenTitle')}
        onClose={onClose}
        footer={
          <>
            <Button variant="outlined" size="m" onClick={onClose}>
              {t('cancel')}
            </Button>
            <Button
              variant="primary"
              size="m"
              onClick={() => {
                onClose()
                openSettings('providers')
              }}
            >
              {t('imageGenConfigure')}
            </Button>
          </>
        }
      >
        <div className={styles.empty}>{t('imageGenNoProvider')}</div>
      </Modal>
    )
  }

  const submit = () => {
    if (!provider || !model.trim() || !prompt.trim()) {
      return
    }
    const ok = generateImage(sessionId, {
      prompt,
      providerId: provider.id,
      model: model.trim(),
      size,
      count,
    })
    if (ok) {
      onClose()
    } else {
      showToast({ key: 'imageGenFailed', type: 'error' })
    }
  }

  return (
    <Modal
      title={t('imageGenTitle')}
      onClose={onClose}
      className={styles.modal}
      footer={
        <>
          <Button variant="outlined" size="m" onClick={onClose}>
            {t('cancel')}
          </Button>
          <Button
            variant="primary"
            size="m"
            disabled={!provider || !model.trim() || !prompt.trim()}
            onClick={submit}
          >
            {t('imageGenGenerate')}
          </Button>
        </>
      }
    >
      <div className={styles.form}>
        <label className={styles.field}>
          <span>{t('imageGenProvider')}</span>
          <Select
            value={providerId}
            options={imageProviders.map((item) => ({ value: item.id, label: item.name }))}
            onChange={(id) => {
              setProviderId(id)
              const next = imageProviders.find((item) => item.id === id)
              setModel(next?.imageModel ?? '')
            }}
            ariaLabel={t('imageGenProvider')}
          />
        </label>
        <label className={styles.field}>
          <span>{t('imageGenModel')}</span>
          <input
            list="image-gen-models"
            value={model}
            placeholder="image-model-id"
            autoCapitalize="off"
            spellCheck={false}
            onChange={(event) => setModel(event.target.value)}
          />
          <datalist id="image-gen-models">
            {imageModels.map((item) => (
              <option key={item.id} value={item.id}>
                {item.displayName ?? item.id}
              </option>
            ))}
          </datalist>
        </label>
        <label className={styles.field}>
          <span>{t('imageGenPrompt')}</span>
          <textarea
            rows={3}
            value={prompt}
            placeholder={t('imageGenPromptPlaceholder')}
            onChange={(event) => setPrompt(event.target.value)}
          />
        </label>
        <div className={styles.row}>
          <label className={styles.field}>
            <span>{t('imageGenSize')}</span>
            <input
              list="image-gen-sizes"
              value={size}
              onChange={(event) => setSize(event.target.value)}
            />
            <datalist id="image-gen-sizes">
              {SIZES.map((value) => (
                <option key={value} value={value} />
              ))}
            </datalist>
          </label>
          <label className={styles.field}>
            <span>{t('imageGenCount')}</span>
            <Select
              value={String(count)}
              options={COUNTS.map((value) => ({ value: String(value), label: String(value) }))}
              onChange={(value) => setCount(Number(value))}
              ariaLabel={t('imageGenCount')}
            />
          </label>
        </div>
        <div className={styles.hint}>{t('imageGenHint')}</div>
      </div>
    </Modal>
  )
}
