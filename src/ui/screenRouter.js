/**
 * (导航员) 管理页面跳转（从“行程库”跳转到“编辑器”）。
 */
export class ScreenRouter {
  constructor() {
    this.stack = [{ name: 'trip_library', params: {} }]
  }

  navigate(name, params = {}) {
    this.stack.push({ name, params: { ...params } })
    return this.getState()
  }

  back() {
    if (this.stack.length > 1) {
      this.stack.pop()
    }
    return this.getState()
  }

  getState() {
    const current = this.stack[this.stack.length - 1]
    return {
      current: { ...current, params: { ...current.params } },
      depth: this.stack.length
    }
  }
}
