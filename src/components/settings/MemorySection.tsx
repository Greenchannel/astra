import { useState } from 'react'
import { useTranslate } from '../../i18n/index.js'
import {
  MAX_MEMORY_ITEMS,
  addMemory,
  clearMemory,
  removeMemory,
  updateMemory,
  useMemory,
} from '../../services/memory/store.js'
import { setMemoryAutoExtract, useSettings } from '../../services/settings.js'
import { Button } from '../base/Button.js'
import { Modal } from '../base/Modal.js'
import styles from './Memory.module.css'

export const MemorySection = () => {
  const t = useTranslate()
  const items = useMemory((state) => state.items)
  const autoExtract = useSettings((state) => state.memoryAutoExtract)
  const [value, setValue] = useState('')
  const [editingId, setEditingId] = useState<string | null>(null)
  const [editingValue, setEditingValue] = useState('')
  const [clearing, setClearing] = useState(false)

  const add = () => {
    if (addMemory(value)) {
      setValue('')
    }
  }

  const startEdit = (id: string, content: string) => {
    setEditingId(id)
    setEditingValue(content)
  }

  const saveEdit = () => {
    if (editingId) {
      updateMemory(editingId, { content: editingValue })
      setEditingId(null)
    }
  }

  return (
    <div className={styles.section}>
      <div className={styles.header}>
        <div>
          <div className={styles.title}>{t('memoryTitle')}</div>
          <div className={styles.description}>{t('memoryDescription')}</div>
        </div>
      </div>

      <label className={styles.autoRow}>
        <input
          type="checkbox"
          checked={autoExtract}
          onChange={(event) => setMemoryAutoExtract(event.target.checked)}
        />
        <span>
          <span className={styles.autoLabel}>{t('memoryAutoExtract')}</span>
          <span className={styles.description}>{t('memoryAutoExtractHint')}</span>
        </span>
      </label>

      <div className={styles.addRow}>
        <textarea
          className={styles.input}
          rows={2}
          value={value}
          placeholder={t('memoryAddPlaceholder')}
          onChange={(event) => setValue(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === 'Enter' && !event.shiftKey && !event.nativeEvent.isComposing) {
              event.preventDefault()
              add()
            }
          }}
        />
        <Button variant="primary" size="m" disabled={!value.trim()} onClick={add}>
          {t('memoryAdd')}
        </Button>
      </div>

      <div className={styles.count}>
        {t('memoryCount', { count: items.length, max: MAX_MEMORY_ITEMS })}
        {items.length > 0 ? (
          <button type="button" className={styles.clear} onClick={() => setClearing(true)}>
            {t('memoryClearAll')}
          </button>
        ) : null}
      </div>

      {items.length === 0 ? (
        <div className={styles.empty}>{t('memoryEmpty')}</div>
      ) : (
        <div className={styles.list}>
          {items.map((item) => (
            <div key={item.id} className={styles.item} data-disabled={!item.enabled || undefined}>
              <input
                type="checkbox"
                aria-label={t('memoryEnabled')}
                checked={item.enabled}
                onChange={(event) => updateMemory(item.id, { enabled: event.target.checked })}
              />
              <div className={styles.itemMain}>
                {editingId === item.id ? (
                  <textarea
                    className={styles.input}
                    rows={2}
                    value={editingValue}
                    autoFocus
                    onChange={(event) => setEditingValue(event.target.value)}
                    onKeyDown={(event) => {
                      if (event.key === 'Enter' && !event.shiftKey && !event.nativeEvent.isComposing) {
                        event.preventDefault()
                        saveEdit()
                      }
                      if (event.key === 'Escape') {
                        setEditingId(null)
                      }
                    }}
                  />
                ) : (
                  <div className={styles.content}>{item.content}</div>
                )}
                <div className={styles.meta}>
                  <span className={styles.source}>
                    {t(item.source === 'auto' ? 'memorySourceAuto' : 'memorySourceManual')}
                  </span>
                </div>
              </div>
              <div className={styles.actions}>
                {editingId === item.id ? (
                  <>
                    <Button variant="primary" size="s" onClick={saveEdit}>
                      {t('save')}
                    </Button>
                    <Button variant="outlined" size="s" onClick={() => setEditingId(null)}>
                      {t('cancel')}
                    </Button>
                  </>
                ) : (
                  <>
                    <Button
                      variant="outlined"
                      size="s"
                      onClick={() => startEdit(item.id, item.content)}
                    >
                      {t('edit')}
                    </Button>
                    <Button variant="dangerOutlined" size="s" onClick={() => removeMemory(item.id)}>
                      {t('delete')}
                    </Button>
                  </>
                )}
              </div>
            </div>
          ))}
        </div>
      )}

      {clearing ? (
        <Modal
          title={t('memoryClearTitle')}
          onClose={() => setClearing(false)}
          footer={
            <>
              <Button variant="outlined" size="m" onClick={() => setClearing(false)}>
                {t('cancel')}
              </Button>
              <Button
                variant="danger"
                size="m"
                onClick={() => {
                  clearMemory()
                  setClearing(false)
                }}
              >
                {t('memoryClearAll')}
              </Button>
            </>
          }
        >
          {t('memoryClearDescription')}
        </Modal>
      ) : null}
    </div>
  )
}
