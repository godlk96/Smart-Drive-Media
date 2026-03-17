import { SeamlessPlayerManager, SeamlessSwapEvent } from './SeamlessPlayerManager'
import { debugLog } from '../utils/Logger'

export class SeamlessPreviewController {
  private bindStart: () => void = () => {}
  private bindPause: () => void = () => {}
  private bindSeek: (timeSec: number) => void = () => {}
  private bindSpeed: (speed: number) => void = () => {}
  private bindMuted: (muted: boolean) => void = () => {}
  private bindReload: (currentUri: string, nextUri: string, startSec: number) => void = () => {}

  attach(
    startFn: () => void,
    pauseFn: () => void,
    seekFn: (timeSec: number) => void,
    speedFn: (speed: number) => void,
    mutedFn: (muted: boolean) => void,
    reloadFn: (currentUri: string, nextUri: string, startSec: number) => void
  ): void {
    this.bindStart = startFn
    this.bindPause = pauseFn
    this.bindSeek = seekFn
    this.bindSpeed = speedFn
    this.bindMuted = mutedFn
    this.bindReload = reloadFn
  }

  start(): void {
    this.bindStart()
  }

  pause(): void {
    this.bindPause()
  }

  setCurrentTime(timeSec: number): void {
    this.bindSeek(timeSec)
  }

  setPlaybackSpeed(speed: number): void {
    this.bindSpeed(speed)
  }

  setMuted(muted: boolean): void {
    this.bindMuted(muted)
  }

  reloadWindow(currentUri: string, nextUri: string, startSec: number): void {
    this.bindReload(currentUri, nextUri, startSec)
  }
}

@Component
export struct SeamlessPreviewView {
  @Prop @Watch('onCurrentUriChanged') currentUri: string = ''
  @Prop @Watch('onNextUriChanged') nextUri: string = ''
  @Prop @Watch('onMutedChanged') muted: boolean = false
  controller?: SeamlessPreviewController
  onSwapCallback?: (event: SeamlessSwapEvent) => void
  onEndedCallback?: () => void
  onErrorCallback?: (message: string) => void

  @State private activeSlot: 'A' | 'B' = 'A'
  private manager: SeamlessPlayerManager = new SeamlessPlayerManager()
  private xControllerA: XComponentController = new XComponentController()
  private xControllerB: XComponentController = new XComponentController()
  private surfaceA: string = ''
  private surfaceB: string = ''
  private currentRate: number = 1
  private targetPlayState: boolean = false
  private lastSeekMs: number = 0

  aboutToAppear(): void {
    this.manager.setCallbacks(
      (event: SeamlessSwapEvent) => {
        this.activeSlot = event.activeSlot
        if (this.onSwapCallback) {
          this.onSwapCallback(event)
        }
      },
      () => {
        if (this.onEndedCallback) {
          this.onEndedCallback()
        }
      },
      (message: string) => {
        debugLog('SeamlessPreviewView', message)
        if (this.onErrorCallback) {
          this.onErrorCallback(message)
        }
      }
    )
    if (this.controller) {
      this.controller.attach(
        () => {
          this.targetPlayState = true
          this.manager.play()
        },
        () => {
          this.targetPlayState = false
          this.manager.pause()
        },
        (timeSec: number) => {
          const seekMs = Math.max(0, Math.floor(timeSec * 1000))
          this.lastSeekMs = seekMs
          this.manager.seek(seekMs)
        },
        (speed: number) => {
          this.currentRate = speed
          this.manager.setPlaybackRate(speed)
        },
        (muted: boolean) => {
          this.manager.setMuted(muted)
        },
        (currentUri: string, nextUri: string, startSec: number) => {
          this.lastSeekMs = Math.max(0, Math.floor(startSec * 1000))
          this.manager.updateWindow(currentUri, nextUri, this.lastSeekMs)
          if (this.targetPlayState) {
            this.manager.play()
          }
        }
      )
    }
  }

  aboutToDisappear(): void {
    this.manager.release()
  }

  private maybeBindManager(): void {
    if (this.surfaceA.length === 0 || this.surfaceB.length === 0) {
      return
    }
    this.manager.attachSurfaces(this.surfaceA, this.surfaceB).then(() => {
      this.manager.setMuted(this.muted)
      this.manager.setPlaybackRate(this.currentRate)
      this.manager.updateWindow(this.currentUri, this.nextUri, this.lastSeekMs)
      if (this.targetPlayState) {
        this.manager.play()
      }
    }).catch((error: Object) => {
      const message = error instanceof Error ? error.message : String(error)
      if (this.onErrorCallback) {
        this.onErrorCallback(message)
      }
    })
  }

  private onCurrentUriChanged(): void {
    this.manager.updateWindow(this.currentUri, this.nextUri, this.lastSeekMs)
  }

  private onNextUriChanged(): void {
    this.manager.updateWindow(this.currentUri, this.nextUri, this.lastSeekMs)
  }

  private onMutedChanged(): void {
    this.manager.setMuted(this.muted)
  }

  build() {
    Stack() {
      XComponent({
        id: 'seamless_x_a',
        type: 'surface',
        controller: this.xControllerA
      })
        .zIndex(this.activeSlot === 'A' ? 2 : 1)
        .opacity(1)
        .width('100%')
        .height('100%')
        .onLoad(() => {
          this.surfaceA = this.xControllerA.getXComponentSurfaceId()
          this.maybeBindManager()
        })
      XComponent({
        id: 'seamless_x_b',
        type: 'surface',
        controller: this.xControllerB
      })
        .zIndex(this.activeSlot === 'B' ? 2 : 1)
        .opacity(1)
        .width('100%')
        .height('100%')
        .onLoad(() => {
          this.surfaceB = this.xControllerB.getXComponentSurfaceId()
          this.maybeBindManager()
        })
    }
    .width('100%')
    .height('100%')
  }
}
