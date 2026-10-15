import { describe, expect, mock, test } from 'claude-code/testing'

const ORGANIZATION = 'ef1479f3-c3ef-442d-9c5b-fd619cd286a8'
const USAGE = { five_hour: { utilization: 12, resets_at: '2026-10-14T03:00:00Z' } }

describe('register', () => {
  test('native mod timer refreshes while the session is idle and stops on session end', async ($, on) => {
    const clock = mock.clock(on, { now: Date.parse('2026-10-14T00:00:00Z') })
    mock.env(on, { HOME: '/bridge-test' })
    const requests: string[] = []
    const readings: unknown[] = []
    on('session.start', (_, e) => ({ cwd: e.cwd }))
    on('session.end', () => ({ sessionId: 'test-session' }))
    on('session.authorize', () => ({ value: { kind: 'bearer', handle: 'opaque' } }))
    on('http.fetch', (_, e) => {
      requests.push(e.url)
      return { value: {
        status: 200, ok: true, headers: {},
        text: JSON.stringify(e.url.endsWith('/profile') ? { organization: { uuid: ORGANIZATION } } : USAGE),
      } }
    })
    on('fs.write', (_, e) => {
      if (e.path.endsWith('/response.json')) readings.push(JSON.parse(e.text))
      return { value: undefined }
    })

    await $.session.start({ cwd: '/project', surface: 'terminal', isInteractive: true })
    await clock.settle()
    expect(requests.length).toBe(2)
    expect(readings.length).toBe(1)
    await clock.advance(270_000)
    expect(requests.length).toBe(2)
    await clock.advance(30_000)
    expect(requests.length).toBe(4)
    expect(readings.length).toBe(2)
    await $.session.end({ reason: 'prompt_input_exit', sessionId: 'test-session', resume: { id: 'test-session' } })
    await clock.advance(300_000)
    expect(requests.length).toBe(4)
  })

  test('native API-key authorization never makes a subscription request', async ($, on) => {
    const clock = mock.clock(on)
    mock.env(on, { HOME: '/bridge-test' })
    const states: string[] = []
    on('session.start', (_, e) => ({ cwd: e.cwd }))
    on('session.authorize', () => ({ value: { kind: 'api-key', handle: 'opaque' } }))
    on('http.fetch', () => { throw new Error('The test must never make a request') })
    on('fs.write', (_, e) => {
      states.push(JSON.parse(e.text).state)
      return { value: undefined }
    })
    await $.session.start({ cwd: '/project', surface: 'terminal', isInteractive: true })
    await clock.settle()
    expect(states).toEqual(['unavailable'])
  })

  test('native 429 path waits fifteen minutes without freshening usage', async ($, on) => {
    const clock = mock.clock(on)
    mock.env(on, { HOME: '/bridge-test' })
    let requests = 0
    const paths: string[] = []
    on('session.start', (_, e) => ({ cwd: e.cwd }))
    on('session.authorize', () => ({ value: { kind: 'bearer', handle: 'opaque' } }))
    on('http.fetch', () => {
      requests += 1
      return { value: { status: 429, ok: false, headers: {}, text: '{}' } }
    })
    on('fs.write', (_, e) => { paths.push(e.path); return { value: undefined } })
    await $.session.start({ cwd: '/project', surface: 'terminal', isInteractive: true })
    await clock.settle()
    expect(requests).toBe(1)
    await clock.advance(870_000)
    expect(requests).toBe(1)
    await clock.advance(30_000)
    expect(requests).toBe(2)
    expect(paths.some(path => path.endsWith('/response.json'))).toBe(false)
  })
})
