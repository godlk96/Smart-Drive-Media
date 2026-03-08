import test from 'node:test'
import assert from 'node:assert/strict'
import { TripLibraryViewModel } from '../src/viewmodel/tripLibraryViewModel.js'

test('TripLibraryViewModel maps trips to library cards', async () => {
  const passiveImportController = {
    async start() {
      return [
        {
          id: 'trip-1',
          startTime: new Date('2026-03-01T09:00:00'),
          endTime: new Date('2026-03-01T09:10:00'),
          duration: 600,
          thumbnailUrl: 'C:/videos/cover1.jpg',
          videoTracks: [{}, {}, {}]
        }
      ]
    }
  }
  const viewModel = new TripLibraryViewModel({ passiveImportController })
  const state = await viewModel.initialize()

  assert.equal(state.scanMode, 'passive')
  assert.equal(state.empty, false)
  assert.equal(state.cards.length, 1)
  assert.equal(state.cards[0].cameraCount, 3)
})

test('TripLibraryViewModel returns empty message when no trips', async () => {
  const passiveImportController = {
    async start() {
      return []
    }
  }
  const viewModel = new TripLibraryViewModel({ passiveImportController })
  const state = await viewModel.initialize()

  assert.equal(state.empty, true)
  assert.equal(state.message, TripLibraryViewModel.emptyMessage)
})
