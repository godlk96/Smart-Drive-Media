/**
 * 全局提示条（snackbar）。
 *
 * 为什么单独抽一个组件：首页和剪辑页原来各写了一份，字号一样、圆角一个 8 一个 10、
 * 时长都写死 2 秒，长文案还会横穿整屏。同一个 App 的同一类反馈不该有两套参数。
 *
 * 形态选的是"底部一条深色短条"，不选浮在页面中央的胶囊：
 * - 中央胶囊挡住正在看的东西，而这几种提示（切太短、切不了、没权限）出现时
 *   用户正盯着轨道或画面；
 * - 底部短条是系统级惯用位置，拇指不挡视线，也不跟任何控件抢位置。
 *
 * 不做的事：不加图标（信息量不足以撑一个图标）、不加渐变和投影（浮层本身有底色，
 * 再叠阴影只会脏）、不自动换行成三段（最多两行，超出省略）。
 */
@Component
export struct AppToast {
  @Prop message: string = ''
  @Prop visible: boolean = false
  /** 可点：目前只有"已保存 · 查看"这类带下一步的提示会用到。 */
  @Prop tappable: boolean = false
  /** 距屏幕底部的距离；剪辑页要抬高，避让底部的导出按钮。 */
  @Prop bottomOffset: number = 40
  onTap?: () => void

  build() {
    if (this.visible && this.message.length > 0) {
      Column() {
        Text(this.message)
          .fontSize(13.5)
          .lineHeight(19)
          .fontColor($r('app.color.card_bg'))
          .textAlign(TextAlign.Center)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .padding({ left: 18, right: 18, top: 11, bottom: 11 })
          .constraintSize({ maxWidth: '78%' })
          .backgroundColor($r('app.color.overlay_veil'))
          .borderRadius(10)
          .onClick(() => {
            if (this.tappable && this.onTap) {
              this.onTap()
            }
          })
      }
      .width('100%')
      // 必须有 height('100%')：否则这个 Column 只有内容那么高，justifyContent(End)
      // 没有可推的空间，提示条会跑到屏幕左上角（真机上就是压在状态栏上）。
      .height('100%')
      .justifyContent(FlexAlign.End)
      .alignItems(HorizontalAlign.Center)
      .padding({ bottom: this.bottomOffset })
      // 外框只负责对齐：自己不吃事件，里面的短条照常可点。
      .hitTestBehavior(HitTestMode.None)
    }
  }
}
