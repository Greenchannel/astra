import { useEffect, useState } from 'react'
import { useTranslate } from '../../i18n/index.js'
import { getCachedBlob } from '../../services/chat/blobCache.js'
import * as db from '../../services/chat/db.js'
import type { GeneratedImage } from '../../services/providers/types.js'
import { saveBlob } from '../../services/platform.js'
import { Button } from '../base/Button.js'
import { Modal } from '../base/Modal.js'
import { showToast } from '../base/toastState.js'
import styles from './GeneratedImages.module.css'

const extensionOf = (mimeType: string) => {
  if (mimeType === 'image/jpeg') {
    return 'jpg'
  }
  if (mimeType === 'image/webp') {
    return 'webp'
  }
  if (mimeType === 'image/gif') {
    return 'gif'
  }
  return 'png'
}

export const GeneratedImages = ({ images }: { images: GeneratedImage[] }) => {
  const t = useTranslate()
  const [urls, setUrls] = useState<Record<string, string>>({})
  const [viewing, setViewing] = useState<GeneratedImage | null>(null)

  useEffect(() => {
    let active = true
    const created: string[] = []
    void (async () => {
      const entries: [string, string][] = []
      for (const image of images) {
        const blob = getCachedBlob(image.id) ?? (await db.loadFile(image.id))
        if (!blob) {
          continue
        }
        const url = URL.createObjectURL(blob)
        created.push(url)
        entries.push([image.id, url])
      }
      if (active) {
        setUrls(Object.fromEntries(entries))
      }
    })()
    return () => {
      active = false
      created.forEach((url) => URL.revokeObjectURL(url))
    }
  }, [images])

  const save = async (image: GeneratedImage) => {
    const blob = getCachedBlob(image.id) ?? (await db.loadFile(image.id))
    if (!blob) {
      showToast({ key: 'imageSaveFailed', type: 'error' })
      return
    }
    try {
      const saved = await saveBlob(blob, `astra-${image.id.slice(0, 8)}.${extensionOf(image.mimeType)}`)
      if (saved) {
        showToast(t('imageSaved'))
      }
    } catch {
      showToast({ key: 'imageSaveFailed', type: 'error' })
    }
  }

  return (
    <div className={styles.wrap}>
      <div className={styles.grid} data-count={images.length}>
        {images.map((image) => (
          <button
            key={image.id}
            type="button"
            className={styles.thumb}
            onClick={() => setViewing(image)}
            aria-label={t('imageOpen')}
          >
            {urls[image.id] ? (
              <img src={urls[image.id]} alt={image.prompt} />
            ) : (
              <span className={styles.placeholder}>{t('imageLoading')}</span>
            )}
          </button>
        ))}
      </div>
      {viewing ? (
        <Modal
          title={viewing.prompt}
          onClose={() => setViewing(null)}
          className={styles.viewer}
          footer={
            <>
              <Button variant="outlined" size="m" onClick={() => setViewing(null)}>
                {t('close')}
              </Button>
              <Button variant="primary" size="m" onClick={() => void save(viewing)}>
                {t('imageSave')}
              </Button>
            </>
          }
        >
          {urls[viewing.id] ? (
            <img className={styles.full} src={urls[viewing.id]} alt={viewing.prompt} />
          ) : null}
          <div className={styles.meta}>
            {viewing.model}
            {viewing.revisedPrompt ? ` · ${viewing.revisedPrompt}` : ''}
          </div>
        </Modal>
      ) : null}
    </div>
  )
}
