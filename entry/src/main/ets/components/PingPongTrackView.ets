import { ActiveLayer, PingPongTrackController } from '../media/PingPongTrackController'

@Component
export struct PingPongTrackView {
  @Prop @Watch('onControllerChanged') controller?: PingPongTrackController
  @Prop onSurfaceReady?: () => void
  @State private activeLayer: ActiveLayer = 'A'
  private xControllerA: XComponentController = new XComponentController()
  private xControllerB: XComponentController = new XComponentController()
  private surfaceA: string = ''
  private surfaceB: string = ''
  private lastBindKey: string = ''
  private bindQueue: Promise<void> = Promise.resolve()
  private bindVersion: number = 0
  private lastReadyBindKey: string = ''

  aboutToAppear(): void {
    this.bindControllerCallback()
    this.bindSurfaceIfReady()
  }

  aboutToDisappear(): void {
    this.bindVersion += 1
    if (this.controller) {
      this.controller.setLayerChangedCallback(undefined)
    }
  }

  private onControllerChanged(): void {
    this.surfaceA = ''
    this.surfaceB = ''
    this.lastBindKey = ''
    this.lastReadyBindKey = ''
    this.bindVersion += 1
    this.bindControllerCallback()
  }

  private bindControllerCallback(): void {
    if (!this.controller) {
      this.activeLayer = 'A'
      return
    }
    this.activeLayer = this.controller.getActiveLayer()
    this.controller.setLayerChangedCallback((layer: ActiveLayer) => {
      this.activeLayer = layer
    })
  }

  private isValidSurfaceId(surfaceId: string): boolean {
    return surfaceId.length > 0 && surfaceId !== '0'
  }

  private bindSurfaceIfReady(): void {
    if (!this.controller) {
      return
    }
    if (!this.isValidSurfaceId(this.surfaceA) || !this.isValidSurfaceId(this.surfaceB)) {
      return
    }
    const bindKey = `${this.controller.getId()}_${this.surfaceA}_${this.surfaceB}`
    if (bindKey === this.lastBindKey) {
      return
    }
    this.lastBindKey = bindKey
    this.bindVersion += 1
    const currentBindVersion = this.bindVersion
    this.bindQueue = this.bindQueue.then(async () => {
      const controller = this.controller
      if (!controller || this.bindVersion !== currentBindVersion) {
        return
      }
      await controller.init(this.surfaceA, this.surfaceB)
      if (this.lastReadyBindKey === bindKey || !this.onSurfaceReady) {
        return
      }
      this.lastReadyBindKey = bindKey
      this.onSurfaceReady()
    }).catch((_error: Object) => {})
  }

  build() {
    Stack() {
      XComponent({
        id: `${this.controller ? this.controller.getId() : 'track'}_a`,
        type: 'surface',
        controller: this.xControllerA
      })
        .width('100%')
        .height('100%')
        .zIndex(this.activeLayer === 'A' ? 2 : 1)
        .onLoad(() => {
          this.surfaceA = this.xControllerA.getXComponentSurfaceId()
          this.bindSurfaceIfReady()
        })
      XComponent({
        id: `${this.controller ? this.controller.getId() : 'track'}_b`,
        type: 'surface',
        controller: this.xControllerB
      })
        .width('100%')
        .height('100%')
        .zIndex(this.activeLayer === 'B' ? 2 : 1)
        .onLoad(() => {
          this.surfaceB = this.xControllerB.getXComponentSurfaceId()
          this.bindSurfaceIfReady()
        })
    }
    .width('100%')
    .height('100%')
  }
}
