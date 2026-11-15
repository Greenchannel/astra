import { useState } from 'react'
import { useTranslate } from '../../i18n/index.js'
import { setSystemPrompt, useSettings } from '../../services/settings.js'
import { Button } from '../base/Button.js'
import styles from './Settings.module.css'

/** 全局自定义 system prompt；留空使用当前供应商默认值 */
export const SystemPromptSetting = () => {
  const t = useTranslate()
  const saved = useSettings((state) => state.systemPrompt) ?? ''
  const [value, setValue] = useState(saved)

  const commit = () => {
    const next = value.trim()
    if (next !== saved) {
      setSystemPrompt(next || null)
    }
  }

  return (
    <div className={styles.systemPrompt}>
      <div className={styles.label}>{t('settingsSystemPrompt')}</div>
      <textarea
        className={styles.systemPromptInput}
        rows={4}
        value={value}
        placeholder={t('settingsSystemPromptPlaceholder')}
        onChange={(event) => setValue(event.target.value)}
        onBlur={commit}
      />
      <div className={styles.systemPromptFooter}>
        <span className={styles.description}>{t('settingsSystemPromptHint')}</span>
        <Button
          variant="outlined"
          size="s"
          disabled={!value.trim() && !saved}
          onClick={() => {
            setValue('')
            setSystemPrompt(null)
          }}
        >
          {t('settingsSystemPromptReset')}
        </Button>
      </div>
    </div>
  )
}
