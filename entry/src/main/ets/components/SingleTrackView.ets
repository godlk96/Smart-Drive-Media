import { SingleTrackController } from '../media/SingleTrackController'

@Component
export struct SingleTrackView {
  controller?: SingleTrackController
  onSurfaceReady?: () => void
  private xController: XComponentController = new XComponentController()

  build() {
    XComponent({
      id: `single_track_${this.controller ? this.controller.getId() : 'default'}`,
      type: 'surface',
      controller: this.xController
    })
      .width('100%')
      .height('100%')
      .onLoad(() => {
        const surfaceId = this.xController.getXComponentSurfaceId()
        if (this.controller && surfaceId && surfaceId.length > 0 && surfaceId !== '0') {
          this.controller.setSurfaceId(surfaceId)
          if (this.onSurfaceReady) {
            this.onSurfaceReady()
          }
        }
      })
  }
}
