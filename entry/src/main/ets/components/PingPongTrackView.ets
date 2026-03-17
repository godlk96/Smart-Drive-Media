import { ActiveLayer, PingPongTrackController } from '../media/PingPongTrackController'

@Component
export struct PingPongTrackView {
  controller?: PingPongTrackController
  @State private activeLayer: ActiveLayer = 'A'
  private xControllerA: XComponentController = new XComponentController()
  private xControllerB: XComponentController = new XComponentController()
  private surfaceA: string = ''
  private surfaceB: string = ''

  aboutToAppear(): void {
    if (!this.controller) {
      return
    }
    this.activeLayer = this.controller.getActiveLayer()
    this.controller.setLayerChangedCallback((layer: ActiveLayer) => {
      this.activeLayer = layer
    })
  }

  private bindSurfaceIfReady(): void {
    if (!this.controller) {
      return
    }
    if (this.surfaceA.length === 0 || this.surfaceB.length === 0) {
      return
    }
    this.controller.init(this.surfaceA, this.surfaceB)
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
