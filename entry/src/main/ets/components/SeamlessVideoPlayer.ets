import media from '@ohos.multimedia.media';
import fs from '@ohos.file.fs';
import audio from '@ohos.multimedia.audio';
import { debugLog } from '../utils/Logger';

export class SeamlessVideoController {
  start: () => void = () => {};
  pause: () => void = () => {};
  setCurrentTime: (timeSec: number) => void = () => {};
  setPlaybackSpeed: (speed: number) => void = () => {};
}

@Component
export struct SeamlessVideoPlayer {
  @Prop @Watch('onSrcChange') src: string = '';
  @Prop @Watch('onMutedChange') muted: boolean = true;
  controller?: SeamlessVideoController;

  onPreparedCallback?: () => void;
  onFinishCallback?: () => void;
  onErrorCallback?: () => void;
  onStartCallback?: () => void;
  onPauseCallback?: () => void;

  private surfaceId: string = '';
  private avPlayer: media.AVPlayer | undefined = undefined;
  private isPrepared: boolean = false;
  private xComponentController: XComponentController = new XComponentController();
  private currentSpeed: number = 1.0;
  private targetPlayState: boolean = false;
  private pendingSeekSec: number = -1;
  private srcChangeVersion: number = 0;
  private listenerVersion: number = 0;

  aboutToAppear() {
    if (this.controller) {
      this.controller.start = () => { 
        this.targetPlayState = true;
        debugLog('Player', `controller.start，prepared=${this.isPrepared}，srcVersion=${this.srcChangeVersion}`);
        if (this.isPrepared && this.avPlayer) {
          try {
            this.avPlayer.play();
          } catch (e) {
            debugLog('Player', 'play failed: ' + String(e));
          }
        }
      };
      this.controller.pause = () => { 
        this.targetPlayState = false;
        debugLog('Player', `controller.pause，prepared=${this.isPrepared}，srcVersion=${this.srcChangeVersion}`);
        if (this.isPrepared && this.avPlayer) {
          try {
            this.avPlayer.pause();
          } catch (e) {
            debugLog('Player', 'pause failed: ' + String(e));
          }
        }
      };
      this.controller.setCurrentTime = (timeSec: number) => { 
        this.pendingSeekSec = Math.max(0, timeSec);
        if (this.isPrepared && this.avPlayer) {
          this.applyPendingSeek('controller');
          return;
        }
        debugLog('Player', `缓存seek，timeSec=${this.pendingSeekSec.toFixed(3)}，prepared=${this.isPrepared}，srcVersion=${this.srcChangeVersion}`);
      };
      this.controller.setPlaybackSpeed = (speed: number) => { 
        this.currentSpeed = speed;
        this.applySpeed(); 
      };
    }
  }

  aboutToDisappear() {
    this.listenerVersion += 1;
    if (this.avPlayer) {
      try {
        this.avPlayer.release();
      } catch (e) {
        debugLog('Player', 'release error: ' + String(e));
      }
    }
  }

  private async setPlayerUrl() {
    if (!this.avPlayer || !this.src) return;
    try {
      if (this.src.startsWith('file://')) {
        let file = fs.openSync(this.src, fs.OpenMode.READ_ONLY);
        this.avPlayer.fdSrc = { fd: file.fd };
      } else {
        this.avPlayer.url = this.src;
      }
    } catch (e) {
      debugLog('Player', 'set url error: ' + String(e));
    }
  }

  private async initPlayer(): Promise<void> {
    this.listenerVersion += 1;
    if (this.avPlayer) {
      try {
        await this.avPlayer.release();
      } catch (e) {
        debugLog('Player', 'release error: ' + String(e));
      }
    }
    try {
      this.avPlayer = await media.createAVPlayer();
      this.avPlayer.audioInterruptMode = audio.InterruptMode.INDEPENDENT_MODE;
      this.setListeners();
      if (this.src && this.surfaceId) {
        await this.setPlayerUrl();
      }
    } catch (e) {
      debugLog('Player', 'create error: ' + String(e));
    }
  }

  private setListeners() {
    if (!this.avPlayer) return;
    const playerRef = this.avPlayer;
    const currentListenerVersion = this.listenerVersion;
    this.avPlayer.on('stateChange', async (state: media.AVPlayerState) => {
      if (!this.avPlayer || this.avPlayer !== playerRef || currentListenerVersion !== this.listenerVersion) {
        debugLog('Player', `忽略过期状态事件，state=${state}，listenerVersion=${currentListenerVersion}/${this.listenerVersion}`);
        return;
      }
      debugLog('Player', `stateChange=${state}，prepared=${this.isPrepared}，targetPlay=${this.targetPlayState}，srcVersion=${this.srcChangeVersion}`);
      switch (state) {
        case 'initialized':
          if (this.avPlayer && this.surfaceId) {
            this.avPlayer.surfaceId = this.surfaceId;
            this.avPlayer.prepare();
          }
          break;
        case 'prepared':
          this.isPrepared = true;
          if (this.avPlayer) {
            this.applySpeed();
            this.applyPendingSeek('prepared');
            try {
              await this.avPlayer.setVolume(this.muted ? 0 : 1);
            } catch (_) {}
            if (this.onPreparedCallback) this.onPreparedCallback();
            if (this.targetPlayState) {
              try {
                this.avPlayer.play();
              } catch (e) {
                debugLog('Player', 'play failed after prepared: ' + String(e));
              }
            }
          }
          break;
        case 'playing':
          if (this.avPlayer) {
            try {
              await this.avPlayer.setVolume(this.muted ? 0 : 1);
            } catch (_) {}
          }
          if (this.onStartCallback) this.onStartCallback();
          break;
        case 'paused':
          if (!this.isPrepared) {
            debugLog('Player', `忽略paused回调，prepared=${this.isPrepared}，srcVersion=${this.srcChangeVersion}`);
            break;
          }
          if (this.onPauseCallback) this.onPauseCallback();
          break;
        case 'completed':
          if (this.onFinishCallback) this.onFinishCallback();
          break;
        case 'error':
          if (this.onErrorCallback) this.onErrorCallback();
          break;
      }
    });
  }

  private applySpeed(): void {
    if (!this.avPlayer || !this.isPrepared) return;
    let playSpeed = media.PlaybackSpeed.SPEED_FORWARD_1_00_X;
    if (this.currentSpeed <= 0.75) { playSpeed = media.PlaybackSpeed.SPEED_FORWARD_0_75_X; }
    else if (this.currentSpeed <= 1.0) { playSpeed = media.PlaybackSpeed.SPEED_FORWARD_1_00_X; }
    else if (this.currentSpeed <= 1.25) { playSpeed = media.PlaybackSpeed.SPEED_FORWARD_1_25_X; }
    else if (this.currentSpeed <= 1.75) { playSpeed = media.PlaybackSpeed.SPEED_FORWARD_1_75_X; }
    else if (this.currentSpeed <= 2.0) { playSpeed = media.PlaybackSpeed.SPEED_FORWARD_2_00_X; }
    else { playSpeed = media.PlaybackSpeed.SPEED_FORWARD_2_00_X; }
    this.avPlayer.setSpeed(playSpeed);
  }

  private applyPendingSeek(reason: string): void {
    if (!this.avPlayer || !this.isPrepared || this.pendingSeekSec < 0) {
      return;
    }
    const seekMs = Math.floor(this.pendingSeekSec * 1000);
    try {
      this.avPlayer.seek(seekMs, media.SeekMode.SEEK_PREV_SYNC);
      debugLog('Player', `应用缓存seek，reason=${reason}，seekMs=${seekMs}，srcVersion=${this.srcChangeVersion}`);
    } catch (e) {
      debugLog('Player', 'seek failed: ' + String(e));
    }
    this.pendingSeekSec = -1;
  }

  private async onSrcChange(): Promise<void> {
    if (!this.avPlayer || !this.surfaceId) {
      debugLog('Player', `跳过切源，播放器未就绪，hasPlayer=${this.avPlayer !== undefined}，surfaceReady=${this.surfaceId.length > 0}`);
      return;
    }
    const opVersion = ++this.srcChangeVersion;
    this.isPrepared = false;
    debugLog('Player', `触发切源，version=${opVersion}，srcLength=${this.src.length}，targetPlay=${this.targetPlayState}`);
    try {
      await this.avPlayer.reset();
      if (opVersion !== this.srcChangeVersion) {
        debugLog('Player', `切源中止（reset后版本过期），version=${opVersion}/${this.srcChangeVersion}`);
        return;
      }
      if (this.avPlayer && this.src) {
        await this.setPlayerUrl();
        debugLog('Player', `切源完成，version=${opVersion}，等待prepared`);
      }
    } catch (e) {
      debugLog('Player', 'reset failed: ' + String(e));
    }
  }

  private async onMutedChange(): Promise<void> {
    if (this.avPlayer && this.isPrepared) {
      try {
        await this.avPlayer.setVolume(this.muted ? 0 : 1);
      } catch (e) {
        debugLog('Player', 'setVolume failed: ' + String(e));
      }
    }
  }

  build() {
    XComponent({
      id: 'video_player_' + Math.random().toString(),
      type: 'surface',
      controller: this.xComponentController
    })
    .onLoad(() => {
      this.surfaceId = this.xComponentController.getXComponentSurfaceId();
      this.initPlayer();
    })
    .width('100%')
    .height('100%')
  }
}
