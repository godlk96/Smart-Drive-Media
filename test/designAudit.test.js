import test from 'node:test'
import assert from 'node:assert/strict'
import { runDesignAudit } from '../src/logic/designAudit.js'
import { Orientation, getEditorLayout } from '../src/logic/editorLayout.js'

test('runDesignAudit passes when dark theme and layout rules are satisfied', () => {
  const result = runDesignAudit({
    theme: 'dark',
    minTouchTarget: 48,
    portraitLayout: getEditorLayout(Orientation.PORTRAIT),
    landscapeLayout: getEditorLayout(Orientation.LANDSCAPE)
  })
  assert.equal(result.passed, true)
  assert.equal(result.failedChecks.length, 0)
})
