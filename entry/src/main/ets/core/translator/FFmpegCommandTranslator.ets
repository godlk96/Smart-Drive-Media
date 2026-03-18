import { ExportSnapshot } from '../../model/Models'
import { Translator } from './Translator'

export class FFmpegCommandTranslator implements Translator<ExportSnapshot, Array<string>> {
  translate(source: ExportSnapshot): Array<string> {
    const args: Array<string> = []
    args.push('-template')
    args.push(source.selectedTemplateId)
    args.push('-range')
    args.push(`${source.playback.rangeStartMs}-${source.playback.rangeEndMs}`)
    args.push('-speed')
    args.push(source.playback.speedLabel)
    args.push('-muted')
    args.push(source.playback.muted ? '1' : '0')
    args.push('-watermark')
    args.push(source.brand.watermarkEnabled ? '1' : '0')
    args.push('-hideSpeed')
    args.push(source.privacy.hideSpeed ? '1' : '0')
    args.push('-hideGps')
    args.push(source.privacy.hideGps ? '1' : '0')
    args.push('-hideTime')
    args.push(source.privacy.hideGps ? '1' : '0')
    args.push('-hideVin')
    args.push(source.privacy.hideVin ? '1' : '0')
    args.push('-trip')
    args.push(source.trip.tripId)
    return args
  }
}
