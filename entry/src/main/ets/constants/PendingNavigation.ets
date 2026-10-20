/**
 * 「导出成功后引导跳转到我的剪辑」的模块级标记。
 *
 * 为什么用模块级可变状态而不是路由参数 / AppStorage：
 * 跳转发生在**两个页面之间**（Editor 导出成功 → 用户点提示 → 回 Index），
 * 而这两页之间只走 `router.back()`，没有机会带参数；AppStorage 又要引入
 * `@ohos.*`，本模块刻意保持**纯模块**（不 import 任何 `@ohos.*`），
 * 这样才能进 `tools/offline-test.mjs` 的离线用例集。
 *
 * 语义是「一次性待办」而不是计数：Editor 置 true，Index 在 `onPageShow`
 * 消费一次后复位。与 Editor.ets 里 `requestPreviewSeek` 的「一次性请求」同构。
 */
let openMyEditsPending: boolean = false

/** 置位「回到首页时切到我的剪辑」。重复调用与调用一次等价。 */
export function requestOpenMyEdits(): void {
  openMyEditsPending = true
}

/**
 * 消费「回到首页时切到我的剪辑」标记：返回是否曾被请求，并**立即复位**。
 * 返回 true 的调用方负责执行跳转；返回 false 表示没有待办。
 */
export function consumeOpenMyEdits(): boolean {
  const pending: boolean = openMyEditsPending
  openMyEditsPending = false
  return pending
}
