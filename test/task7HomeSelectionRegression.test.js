import { test } from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'

const indexPath = path.resolve(process.cwd(), 'entry/src/main/ets/pages/Index.ets')
const homeViewModelPath = path.resolve(process.cwd(), 'entry/src/main/ets/viewmodel/HomeViewModel.ets')

test('Task7: Index 多选显示逻辑基于本地状态并在>=2时显示合并按钮', () => {
  const source = fs.readFileSync(indexPath, 'utf8')
  assert.equal(source.includes('return this.selectedTripIds.some((id: string) => id === cardId)'), true)
  assert.equal(source.includes('return this.selectionMode && this.selectedTripIds.length >= 2'), true)
})

test('Task7: HomeViewModel 仅在多选模式且卡片存在时允许切换选中态', () => {
  const source = fs.readFileSync(homeViewModelPath, 'utf8')
  assert.equal(source.includes('if (!this.state.selectionMode) {'), true)
  assert.equal(source.includes('const existsInLibrary = this.state.libraryState.cards.some((item: TripCardModel) => item.id === cardId)'), true)
  assert.equal(source.includes('if (!existsInLibrary) {'), true)
})
