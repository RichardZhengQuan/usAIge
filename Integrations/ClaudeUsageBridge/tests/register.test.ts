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

  test('native collector holds one background task while idle and stops it at session end', async ($, on) => {
    const clock = mock.clock(on, { now: Date.parse('2026-10-14T00:00:00Z') })
    mock.env(on, { HOME: '/bridge-test' })
    const files = new Map<string, string>()
    const calls: string[] = []
    const lease = () => JSON.parse(files.get('/bridge-test/Library/Application Support/usAIge/claude-usage/keep-alive.json') ?? 'null')
    on('session.start', (_, e) => ({ cwd: e.cwd }))
    on('session.end', () => ({ sessionId: 'test-session' }))
    on('session.id', () => ({ value: 'test-session' }))
    on('session.authorize', () => ({ value: { kind: 'bearer', handle: 'opaque' } }))
    on('http.fetch', (_, e) => ({ value: {
      status: 200, ok: true, headers: {},
      text: JSON.stringify(e.url.endsWith('/profile') ? { organization: { uuid: ORGANIZATION } } : USAGE),
    } }))
    on('fs.write', (_, e) => { files.set(e.path, e.text); return { value: undefined } })
    on('fs.read', (_, e) => files.has(e.path) ? { value: files.get(e.path) as string } : { deny: 'missing' })
    on('tool.call', (_, e) => {
      const input = e as Record<string, unknown>
      calls.push(input.tool === 'Bash' ? `Bash background=${input.run_in_background}` : `${input.tool} ${input.task_id}`)
      return input.tool === 'Bash'
        ? { result: { stdout: '', stderr: '', interrupted: false, backgroundTaskId: 'task-1' } }
        : { result: { message: 'stopped', task_id: 'task-1', task_type: 'local_bash' } }
    })

    await $.session.start({ cwd: '/project', surface: 'terminal', isInteractive: true })
    await clock.settle()
    expect(calls).toEqual(['Bash background=true'])
    expect(lease()?.taskID).toBe('task-1')
    await clock.advance(30 * 60_000)
    expect(calls).toEqual(['Bash background=true'])
    expect(lease()?.renewedAt).toBe('2026-10-14T00:30:00.000Z')
    await $.session.end({ reason: 'prompt_input_exit', sessionId: 'test-session', resume: { id: 'test-session' } })
    await clock.settle()
    expect(calls).toEqual(['Bash background=true', 'TaskStop task-1'])
  })

  test('native resumed session replaces the task named by its own expired lease', async ($, on) => {
    const clock = mock.clock(on, { now: Date.parse('2026-10-14T00:00:00Z') })
    mock.env(on, { HOME: '/bridge-test' })
    const path = '/bridge-test/Library/Application Support/usAIge/claude-usage/keep-alive.json'
    // An earlier engine for this session stopped without session.end.
    const files = new Map([[path, JSON.stringify({
      schemaVersion: 1, sessionID: 'test-session', renewedAt: '2026-10-13T23:50:00.000Z', taskID: 'stopped-engine-task',
    })]])
    const calls: string[] = []
    on('session.start', (_, e) => ({ cwd: e.cwd }))
    on('session.id', () => ({ value: 'test-session' }))
    on('session.authorize', () => ({ value: { kind: 'bearer', handle: 'opaque' } }))
    on('http.fetch', (_, e) => ({ value: {
      status: 200, ok: true, headers: {},
      text: JSON.stringify(e.url.endsWith('/profile') ? { organization: { uuid: ORGANIZATION } } : USAGE),
    } }))
    on('fs.write', (_, e) => { files.set(e.path, e.text); return { value: undefined } })
    on('fs.read', (_, e) => files.has(e.path) ? { value: files.get(e.path) as string } : { deny: 'missing' })
    on('tool.call', (_, e) => {
      calls.push(String((e as Record<string, unknown>).tool))
      return { result: { stdout: '', stderr: '', interrupted: false, backgroundTaskId: 'task-1' } }
    })

    await $.session.start({ cwd: '/project', surface: 'terminal', isInteractive: true })
    await clock.settle()
    expect(calls).toEqual(['Bash'])
    expect(JSON.parse(files.get(path) as string)).toEqual({
      schemaVersion: 1, sessionID: 'test-session', renewedAt: '2026-10-14T00:00:00.000Z', taskID: 'task-1',
    })
  })

  test('native denied keep-alive start is not asked again while the session runs', async ($, on) => {
    const clock = mock.clock(on, { now: Date.parse('2026-10-14T00:00:00Z') })
    mock.env(on, { HOME: '/bridge-test' })
    const files = new Map<string, string>()
    const calls: string[] = []
    let readings = 0
    on('session.start', (_, e) => ({ cwd: e.cwd }))
    on('session.id', () => ({ value: 'test-session' }))
    on('session.authorize', () => ({ value: { kind: 'bearer', handle: 'opaque' } }))
    on('http.fetch', (_, e) => ({ value: {
      status: 200, ok: true, headers: {},
      text: JSON.stringify(e.url.endsWith('/profile') ? { organization: { uuid: ORGANIZATION } } : USAGE),
    } }))
    on('fs.write', (_, e) => {
      files.set(e.path, e.text)
      if (e.path.endsWith('/response.json')) readings += 1
      return { value: undefined }
    })
    on('fs.read', (_, e) => files.has(e.path) ? { value: files.get(e.path) as string } : { deny: 'missing' })
    on('tool.call', (_, e) => {
      calls.push(String((e as Record<string, unknown>).tool))
      return { deny: 'The person declined this command' }
    })

    await $.session.start({ cwd: '/project', surface: 'terminal', isInteractive: true })
    await clock.settle()
    expect(calls).toEqual(['Bash'])
    // Past the earlier fifteen-minute retry, usage still refreshing.
    await clock.advance(30 * 60_000)
    expect(calls).toEqual(['Bash'])
    expect(readings).toBe(7)
    expect([...files.keys()].some(path => path.endsWith('/keep-alive.json'))).toBe(false)
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
