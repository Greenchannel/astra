import { useState } from 'react'
import { createPortal } from 'react-dom'
import { useTranslate } from '../../i18n/index.js'
import {
  selectChatModel,
  setActiveProvider,
  useProviders,
} from '../../services/providers/store.js'
import { useAnchoredPosition, useDismiss } from '../base/anchored.js'
import { IconChevronDownOutline14, IconServerOutline16 } from '../base/icons.js'
import { openSettings } from '../settings/settingsDialogState.js'
import styles from './ModelPicker.module.css'

/** 输入区模型胶囊：按供应商分组展示全部已检测/手填模型，选中后自动切换供应商 */
export const ModelPicker = () => {
  const t = useTranslate()
  const providers = useProviders((state) => state.providers)
  const activeId = useProviders((state) => state.activeId)
  const [open, setOpen] = useState(false)
  const active = providers.find((provider) => provider.id === activeId) ?? null
  const hasModels = providers.some((provider) => provider.chatModel)
  const { anchorRef, floatingRef, position } = useAnchoredPosition<HTMLSpanElement, HTMLDivElement>(
    open,
    {
      side: 'top',
      align: 'start',
      offset: 6,
      maxHeight: 360,
      minSpace: 200,
      measureKey: providers,
    }
  )
  useDismiss(open, [anchorRef, floatingRef], () => setOpen(false))

  return (
    <>
      <span ref={anchorRef} className={styles.anchor}>
        <button
          type="button"
          className={styles.trigger}
          aria-haspopup="menu"
          aria-expanded={open}
          onClick={() => setOpen((value) => !value)}
        >
          <IconServerOutline16 />
          <span className={styles.label}>
            {active?.chatModel ? `${active.name} · ${active.chatModel}` : t('modelPickerChoose')}
          </span>
          <IconChevronDownOutline14 />
        </button>
      </span>
      {open
        ? createPortal(
            <div
              ref={floatingRef}
              className={styles.panel}
              style={position ?? undefined}
              role="menu"
            >
              {hasModels ? (
                providers.map((provider) =>
                  provider.chatModel ? (
                    <div key={provider.id} className={styles.group}>
                      <div className={styles.groupHeader}>{provider.name}</div>
                      <button
                        type="button"
                        role="menuitemradio"
                        aria-checked={
                          provider.id === activeId && provider.chatModel === active?.chatModel
                        }
                        className={styles.option}
                        onClick={() => {
                          selectChatModel(provider.id, provider.chatModel ?? '')
                          setOpen(false)
                        }}
                      >
                        <span className={styles.optionId}>{provider.chatModel}</span>
                        {provider.id === activeId ? (
                          <span className={styles.activeMark}>{t('modelPickerActive')}</span>
                        ) : null}
                      </button>
                      {provider.models
                        .filter(
                          (model) =>
                            model.kind === 'chat' && model.id !== provider.chatModel
                        )
                        .map((model) => (
                          <button
                            key={model.id}
                            type="button"
                            role="menuitemradio"
                            aria-checked={false}
                            className={styles.option}
                            onClick={() => {
                              selectChatModel(provider.id, model.id)
                              setOpen(false)
                            }}
                          >
                            <span className={styles.optionId}>{model.displayName ?? model.id}</span>
                          </button>
                        ))}
                    </div>
                  ) : null
                )
              ) : (
                <div className={styles.empty}>{t('modelPickerEmpty')}</div>
              )}
              <button
                type="button"
                className={styles.manage}
                onClick={() => {
                  setOpen(false)
                  openSettings('providers')
                }}
              >
                {t('modelPickerManage')}
              </button>
            </div>,
            document.body
          )
        : null}
    </>
  )
}

export const useActiveProvider = () => {
  const providers = useProviders((state) => state.providers)
  const activeId = useProviders((state) => state.activeId)
  return providers.find((provider) => provider.id === activeId) ?? null
}

export const switchProvider = setActiveProvider
