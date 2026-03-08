import hilog from '@ohos.hilog'

const LOG_DOMAIN: number = 0x3200
const LOG_TAG: string = '智驾影音'

export function debugLog(scope: string, message: string): void {
  const text = `【${scope}】${message}`
  hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', text)
  console.info(text)
}
