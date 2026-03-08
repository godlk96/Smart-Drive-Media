import test from 'node:test'
import assert from 'node:assert/strict'
import { TripLibraryViewModel } from '../src/viewmodel/tripLibraryViewModel.js'
import { TripLibraryScreenAdapter } from '../src/ui/tripLibraryScreenAdapter.js'
import { ScreenRouter } from '../src/ui/screenRouter.js'

test('TripLibraryScreenAdapter builds card list and routes to editor', async () => {
  const viewModel = new TripLibraryViewModel({
    passiveImportController: {
      async start() {
        return [
          {
            id: 'trip-1',
            startTime: new Date('2026-03-01T09:00:00'),
            endTime: new Date('2026-03-01T09:10:00'),
            duration: 600,
            thumbnailUrl: 'cover.jpg',
            videoTracks: [{}, {}]
          }
        ]
      }
    }
  })
  const adapter = new TripLibraryScreenAdapter({
    viewModel,
    router: new ScreenRouter()
  })

  const state = await adapter.initialize()
  assert.equal(state.empty, false)
  assert.equal(state.cards.length, 1)
  assert.equal(state.cards[0].subtitle.includes('2 视角'), true)

  adapter.openTrip('trip-1')
  assert.equal(adapter.getState().route.current.name, 'editor')
})
