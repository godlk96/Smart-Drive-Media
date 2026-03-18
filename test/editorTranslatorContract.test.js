import test from 'node:test'
import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'

const projectRoot = new URL('../', import.meta.url)

async function readProjectFile(relativePath) {
  return readFile(new URL(relativePath, projectRoot), 'utf8')
}

test('translator contract keeps preview and export from same EditorState source', async () => {
  const viewModelSource = await readProjectFile('entry/src/main/ets/viewmodel/EditorViewModel.ets')
  assert.equal(viewModelSource.includes('buildPreviewPayload(state: EditorStateModel)'), true)
  assert.equal(viewModelSource.includes('buildExportSnapshot(state: EditorStateModel, exportSessionSeed: string)'), true)
  assert.equal(viewModelSource.includes('this.previewPayloadTranslator.translate(state)'), true)
  assert.equal(viewModelSource.includes('editorState: state'), true)
})

test('FFmpegCommandTranslator covers privacy and deterministic core args', async () => {
  const translatorSource = await readProjectFile('entry/src/main/ets/core/translator/FFmpegCommandTranslator.ets')
  const mustContain = [
    '-template',
    '-range',
    '-speed',
    '-muted',
    '-watermark',
    '-hideSpeed',
    '-hideGps',
    '-hideTime',
    '-hideVin',
    '-trip'
  ]
  mustContain.forEach((flag) => {
    assert.equal(translatorSource.includes(`args.push('${flag}')`), true)
  })
})

test('domain EditorState keeps privacyConfig maskSpeed maskVin maskTime', async () => {
  const editorStateSource = await readProjectFile('entry/src/main/ets/model/EditorState.ets')
  assert.equal(editorStateSource.includes('maskSpeed: boolean'), true)
  assert.equal(editorStateSource.includes('maskVin: boolean'), true)
  assert.equal(editorStateSource.includes('maskTime: boolean'), true)
  assert.equal(editorStateSource.includes('maskTime: viewState.hideGps'), true)
})
