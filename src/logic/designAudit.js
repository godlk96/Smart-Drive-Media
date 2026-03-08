/**
 * (安检员) 检查设计规范符合度（如按钮够不够大）。
 */
export function runDesignAudit({ theme, minTouchTarget, portraitLayout, landscapeLayout }) {
  const checks = {
    theme: theme === 'dark',
    touchTarget: Number(minTouchTarget) >= 44,
    portraitLayout:
      portraitLayout?.preview?.region === 'top' && portraitLayout?.timeline?.region === 'bottom',
    landscapeLayout:
      landscapeLayout?.preview?.region === 'left' && landscapeLayout?.timeline?.region === 'right'
  }

  const failed = Object.entries(checks)
    .filter(([, passed]) => !passed)
    .map(([key]) => key)

  return {
    passed: failed.length === 0,
    failedChecks: failed
  }
}
