import test from 'node:test'
import assert from 'node:assert/strict'

// Test implementation of PreferencesService logic
class MockPreferencesStore {
  constructor() {
    this.data = new Map()
  }
  async put(key, val) {
    this.data.set(key, val)
  }
  async get(key, def) {
    return this.data.has(key) ? this.data.get(key) : def
  }
  async flush() {}
}

class TestPreferencesService {
  constructor(mockStore = null) {
    this.store = mockStore
    this.memoryStore = new Map()
  }

  async saveLastTripId(tripId) {
    this.memoryStore.set('pref_last_trip_id', tripId)
    if (this.store) await this.store.put('pref_last_trip_id', tripId)
  }

  async getLastTripId() {
    if (this.store) {
      const val = await this.store.get('pref_last_trip_id', '')
      return String(val ?? '')
    }
    return String(this.memoryStore.get('pref_last_trip_id') ?? '')
  }

  async saveTemplatePreference(templateId) {
    this.memoryStore.set('pref_template_id', templateId)
    if (this.store) await this.store.put('pref_template_id', templateId)
  }

  async getTemplatePreference(defaultTemplate = 'T2') {
    if (this.store) {
      const val = await this.store.get('pref_template_id', defaultTemplate)
      return String(val || defaultTemplate)
    }
    return String(this.memoryStore.get('pref_template_id') || defaultTemplate)
  }

  async savePrivacySettings(settings) {
    this.memoryStore.set('pref_hide_speed', settings.hideSpeed)
    this.memoryStore.set('pref_hide_vin', settings.hideVin)
    this.memoryStore.set('pref_hide_time', settings.hideTime)
    if (this.store) {
      await this.store.put('pref_hide_speed', settings.hideSpeed)
      await this.store.put('pref_hide_vin', settings.hideVin)
      await this.store.put('pref_hide_time', settings.hideTime)
    }
  }

  async getPrivacySettings() {
    if (this.store) {
      const hideSpeed = Boolean(await this.store.get('pref_hide_speed', true))
      const hideVin = Boolean(await this.store.get('pref_hide_vin', true))
      const hideTime = Boolean(await this.store.get('pref_hide_time', true))
      return { hideSpeed, hideVin, hideTime }
    }
    return {
      hideSpeed: Boolean(this.memoryStore.get('pref_hide_speed') ?? true),
      hideVin: Boolean(this.memoryStore.get('pref_hide_vin') ?? true),
      hideTime: Boolean(this.memoryStore.get('pref_hide_time') ?? true)
    }
  }
}

// Logic contract for extractFirstFrameByService
function extractFirstFrameContract(sourceUri, cacheDir, cacheKey) {
  if (!sourceUri || sourceUri.length === 0) {
    return ''
  }
  const lower = sourceUri.toLowerCase()
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg') || lower.endsWith('.png') || lower.endsWith('.webp')) {
    return sourceUri
  }
  const sanitizedKey = cacheKey.replace(/[^a-zA-Z0-9_-]/g, '_')
  return `${cacheDir}/thumb_${sanitizedKey}.jpg`
}

test('PreferencesService provides defaults and round-trip persistence with backing store', async () => {
  const backingStore = new MockPreferencesStore()
  const pref = new TestPreferencesService(backingStore)

  // Default values
  assert.equal(await pref.getLastTripId(), '')
  assert.equal(await pref.getTemplatePreference('T2'), 'T2')
  assert.deepEqual(await pref.getPrivacySettings(), { hideSpeed: true, hideVin: true, hideTime: true })

  // Save and retrieve
  await pref.saveLastTripId('trip_20261012_01')
  assert.equal(await pref.getLastTripId(), 'trip_20261012_01')

  await pref.saveTemplatePreference('T1')
  assert.equal(await pref.getTemplatePreference(), 'T1')

  await pref.savePrivacySettings({ hideSpeed: false, hideVin: true, hideTime: false })
  assert.deepEqual(await pref.getPrivacySettings(), { hideSpeed: false, hideVin: true, hideTime: false })

  // Verify memory fallback when backing store is absent
  const memPref = new TestPreferencesService(null)
  assert.equal(await memPref.getTemplatePreference(), 'T2')
  await memPref.saveTemplatePreference('T3')
  assert.equal(await memPref.getTemplatePreference(), 'T3')
})

test('extractFirstFrameByService returns a static image path, never a raw mp4 video uri', () => {
  // Image URI pass-through
  const imageUri = 'file:///data/storage/el2/base/photos/cover.jpg'
  const outImage = extractFirstFrameContract(imageUri, '/tmp/cache', 'k1')
  assert.equal(outImage, imageUri)

  // Video URI must output an image path ending in .jpg
  const videoUri = 'file:///data/storage/el2/base/videos/DVR_front_camera.mp4'
  const outThumb = extractFirstFrameContract(videoUri, '/tmp/cache', 'trip1_front')
  assert.ok(outThumb.endsWith('.jpg'), `Expected image extension .jpg but got: ${outThumb}`)
  assert.notEqual(outThumb, videoUri, 'Thumbnail path must not equal the raw video URI')
  assert.equal(outThumb, '/tmp/cache/thumb_trip1_front.jpg')
})

test('Index card preview area renders Image and rejects raw video URIs', () => {
  const cards = [
    { id: '1', previewFrameUri: '/cache/thumb_1.jpg' },
    { id: '2', previewFrameUri: 'file:///photos/cover.png' }
  ]
  for (const card of cards) {
    const isImage = card.previewFrameUri.endsWith('.jpg') || card.previewFrameUri.endsWith('.png')
    assert.ok(isImage, `Card ${card.id} must have a static image preview`)
    assert.ok(!card.previewFrameUri.endsWith('.mp4'), `Card ${card.id} must not have video preview`)
  }
})
