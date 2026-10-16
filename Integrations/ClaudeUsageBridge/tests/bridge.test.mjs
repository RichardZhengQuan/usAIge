import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { test } from 'node:test'
import { KEEP_ALIVE_COMMAND, createUsageCollector, filterUsage, register } from '../hooks/register.mjs'

const ORGANIZATION = 'EF1479F3-C3EF-442D-9C5B-FD619CD286A8'
const DIRECTORY = '/test-home/Library/Application Support/usAIge/claude-usage'
const USAGE = {
  five_hour: { utilization: 12, resets_at: '2026-10-14T03:00:00Z' },
  seven_day: { utilization: 37, resets_at: '2026-10-20T03:00:00Z' },
}
const response = (body, status = 200, headers = {}) => ({ ok: status >= 200 && status < 300, status, headers, text: JSON.stringify(body) })

function fixture() {
  let now = Date.parse('2026-10-14T00:00:00Z')
  const requests = [], writes = [], envReads = [], timers = []
  const engine = {
    env: { get: async key => { envReads.push(key); return '/test-home' } },
    clock: {
      now: async () => now,
      every: (ms, callback) => {
        const timer = { ms, callback, canceled: false, cancel() { this.canceled = true } }
        timers.push(timer)
        return timer
      },
    },
    session: { authorize: async () => ({ kind: 'bearer', handle: 'opaque-handle' }) },
    http: { fetch: async (url, init) => {
      requests.push({ url, init })
      return url.endsWith('/profile') ? response({ organization: { uuid: ORGANIZATION }, account: { email: 'private@example.test' } }) : response(USAGE)
    } },
    fs: { write: async (path, content) => { writes.push({ path, value: JSON.parse(content) }) } },
  }
  return {
    engine, requests, writes, envReads, timers,
    advance(ms) { now += ms },
    tick() { for (const timer of timers) if (!timer.canceled) timer.callback() },
    latest(path = `${DIRECTORY}/response.json`) { return writes.filter(write => write.path === path).at(-1)?.value },
    async settle() { for (let i = 0; i < 30; i++) await Promise.resolve() },
  }
}

test('start requests profile then usage with an opaque bearer handle and emits only bound usage', async () => {
  const f = fixture(), collector = createUsageCollector(f.engine)
  await collector.start()
  assert.equal(f.requests.length, 2)
  assert.deepEqual(f.requests.map(request => request.url), ['https://api.anthropic.com/api/oauth/profile', 'https://api.anthropic.com/api/oauth/usage'])
  for (const { init } of f.requests) assert.deepEqual(init, { method: 'GET', headers: { 'anthropic-beta': 'oauth-2025-04-20' }, auth: 'opaque-handle' })
  assert.deepEqual(f.latest(), { schemaVersion: 1, observedAt: '2026-10-14T00:00:00.000Z', organizationID: ORGANIZATION.toLowerCase(), usage: USAGE })
  assert.deepEqual(f.envReads, ['HOME'])
  assert.equal(JSON.stringify(f.writes).includes('opaque-handle'), false)
  assert.equal(JSON.stringify(f.writes).includes('private@example.test'), false)
})

test('idle timer refreshes at five minutes without events, with a thirty-second check', async () => {
  const f = fixture(), collector = createUsageCollector(f.engine)
  await collector.start()
  assert.equal(f.timers[0].ms, 30_000)
  for (let i = 0; i < 9; i++) { f.advance(30_000); f.tick(); await f.settle() }
  assert.equal(f.requests.length, 2)
  f.advance(30_000); f.tick(); await f.settle()
  assert.equal(f.requests.length, 4)
  assert.equal(f.latest().observedAt, '2026-10-14T00:05:00.000Z')
})

test('a concurrent tick never starts a second request while the first refresh is pending', async () => {
  const f = fixture()
  let release
  f.engine.session.authorize = () => new Promise(resolve => { release = resolve })
  const collector = createUsageCollector(f.engine), pending = collector.start()
  await f.settle()
  f.advance(10 * 60_000); f.tick(); f.tick(); await collector.refresh()
  assert.equal(f.requests.length, 0)
  release({ kind: 'bearer', handle: 'opaque-handle' })
  await pending
  assert.equal(f.requests.length, 2)
})

test('an API-key session makes no usage or profile requests and retries without a sign-in flow', async () => {
  const f = fixture()
  f.engine.session.authorize = async () => ({ kind: 'api-key', handle: 'opaque-api-handle' })
  await createUsageCollector(f.engine).start()
  assert.equal(f.requests.length, 0)
  assert.equal(f.latest(), undefined)
  assert.equal(f.latest(`${DIRECTORY}/status.json`).reason, 'no_subscription_session')
})

test('an invalid organization never fetches usage or overwrites a successful reading', async () => {
  const f = fixture(), collector = createUsageCollector(f.engine)
  await collector.start()
  const previous = f.latest()
  f.engine.http.fetch = async url => { f.requests.push({ url }); return response({ organization: { uuid: 'not-a-uuid' } }) }
  f.advance(5 * 60_000); await collector.refresh()
  assert.equal(f.requests.length, 3)
  assert.deepEqual(f.latest(), previous)
  assert.equal(f.latest(`${DIRECTORY}/status.json`).reason, 'refresh_failed')
})

test('rate limiting keeps the observation unchanged and delays another request fifteen minutes', async () => {
  const f = fixture(), collector = createUsageCollector(f.engine)
  await collector.start()
  const previous = f.latest()
  f.engine.http.fetch = async url => {
    f.requests.push({ url })
    return url.endsWith('/profile') ? response({ organization: { uuid: ORGANIZATION } }) : response({ private_error_body: 'never-save' }, 429)
  }
  f.advance(5 * 60_000); await collector.refresh()
  assert.deepEqual(f.latest(), previous)
  assert.equal(f.latest(`${DIRECTORY}/status.json`).nextAttemptAt, '2026-10-14T00:20:00.000Z')
  const count = f.requests.length
  f.advance(14 * 60_000); await collector.refresh()
  assert.equal(f.requests.length, count)
  f.advance(60_000); await collector.refresh()
  assert.equal(f.requests.length, count + 2)
  assert.equal(JSON.stringify(f.writes).includes('never-save'), false)
})

test('a longer Retry-After is respected, including an absolute HTTP date', async () => {
  for (const header of ['1800', 'Wed, 14 Oct 2026 00:30:00 GMT']) {
    const f = fixture()
    f.engine.http.fetch = async () => response({}, 429, { 'retry-after': header })
    await createUsageCollector(f.engine).start()
    assert.equal(f.latest(`${DIRECTORY}/status.json`).nextAttemptAt, '2026-10-14T00:30:00.000Z')
  }
})

test('network failures keep the observation timestamp and retry after two minutes', async () => {
  const f = fixture(), collector = createUsageCollector(f.engine)
  await collector.start()
  const previous = f.latest()
  f.engine.http.fetch = async () => { throw new Error('sensitive-error-detail') }
  f.advance(5 * 60_000); await collector.refresh()
  assert.deepEqual(f.latest(), previous)
  assert.equal(f.latest(`${DIRECTORY}/status.json`).nextAttemptAt, '2026-10-14T00:07:00.000Z')
  assert.equal(JSON.stringify(f.writes).includes('sensitive-error-detail'), false)
})

test('a switched organization binds failure status before usage, without marking the old response current', async () => {
  const f = fixture(), collector = createUsageCollector(f.engine)
  await collector.start()
  const previous = f.latest()
  const nextOrganization = '39A57C3B-52CB-44E5-A02D-EB6A54DC7C6F'
  f.engine.http.fetch = async url => url.endsWith('/profile') ? response({ organization: { uuid: nextOrganization } }) : response({}, 503)
  f.advance(5 * 60_000); await collector.refresh()
  assert.deepEqual(f.latest(), previous)
  assert.equal(f.latest(`${DIRECTORY}/status.json`).organizationID, nextOrganization.toLowerCase())
  assert.equal(f.latest(`${DIRECTORY}/status.json`).state, 'error')
  assert.equal(f.writes.filter(write => write.path.endsWith('/status.json')).at(-2).value.organizationID, nextOrganization.toLowerCase())
  f.engine.http.fetch = async () => response({}, 503)
  f.advance(2 * 60_000); await collector.refresh()
  assert.equal(f.latest(`${DIRECTORY}/status.json`).organizationID, undefined)
})

test('malformed usage cannot freshen the response or pass unknown fields into it', async () => {
  const f = fixture(), collector = createUsageCollector(f.engine)
  await collector.start()
  const previous = f.latest()
  f.engine.http.fetch = async url => url.endsWith('/profile') ? response({ organization: { uuid: ORGANIZATION } }) : response({ limits: [{ kind: 'session', percent: 'NaN' }] })
  f.advance(5 * 60_000); await collector.refresh()
  assert.deepEqual(f.latest(), previous)
  assert.equal(filterUsage({ token: 'secret' }), null)
  assert.deepEqual(filterUsage({
    limits: [{ kind: 'weekly_scoped', percent: 40, secret: 'secret', scope: { model: { display_name: 'Opus', token: 'secret' }, account: 'secret' } }],
    five_hour: { utilization: 12, resets_at: null, token: 'secret' }, account: 'secret',
    extra_usage: { is_enabled: true, used_credits: 100, resets_at: '2026-11-01T00:00:00Z', token: 'secret' },
  }), {
    limits: [{ kind: 'weekly_scoped', percent: 40, scope: { model: { display_name: 'Opus' } } }],
    five_hour: { utilization: 12, resets_at: null }, extra_usage: { is_enabled: true, used_credits: 100, resets_at: '2026-11-01T00:00:00Z' },
  })
})

test('session end cancels the timer and prevents an in-flight response from landing', async () => {
  const f = fixture()
  let release
  f.engine.http.fetch = url => url.endsWith('/profile') ? Promise.resolve(response({ organization: { uuid: ORGANIZATION } })) : new Promise(resolve => { release = resolve })
  const collector = createUsageCollector(f.engine), pending = collector.start()
  await f.settle()
  collector.stop()
  release(response(USAGE)); await pending
  assert.equal(f.timers[0].canceled, true)
  assert.equal(f.latest(), undefined)
  f.advance(5 * 60_000); f.tick(); await f.settle()
  assert.equal(f.latest(), undefined)
})

test('session end during pending authorization cannot send a late profile request', async () => {
  const f = fixture()
  let release
  f.engine.session.authorize = () => new Promise(resolve => { release = resolve })
  const collector = createUsageCollector(f.engine), pending = collector.start()
  await f.settle()
  collector.stop()
  release({ kind: 'bearer', handle: 'opaque-handle' }); await pending
  assert.equal(f.requests.length, 0)
})

test('malformed modern limits cannot downgrade to legacy usage, and invalid metadata is rejected', () => {
  assert.equal(filterUsage({ ...USAGE, limits: [{ kind: 'session', percent: 'bad' }] }), null)
  assert.equal(filterUsage({ ...USAGE, limits: [{ kind: 'session', percent: 12 }, { kind: 'weekly_all', percent: NaN }] }), null)
  assert.equal(filterUsage({ five_hour: { utilization: -1 } }), null)
  assert.equal(filterUsage({ seven_day: { utilization: 101 } }), null)
  assert.equal(filterUsage({ five_hour: { utilization: 12, resets_at: 'invalid-date' } }), null)
  assert.equal(filterUsage({ limits: [{ kind: 'session', percent: 12, resets_at: 'tomorrow' }] }), null)
})

function registered() {
  const hooks = new Map()
  register((name, ...rest) => hooks.set(name, { matcher: rest.length > 1 ? rest[0] : undefined, hook: rest.at(-1) }))
  return hooks
}

test('registration touches only session start, restart, and end, preserving the native chain', async () => {
  const f = fixture(), hooks = registered()
  assert.deepEqual([...hooks.keys()], ['session.start', 'classic.SessionStart', 'session.end'])
  assert.equal(hooks.get('session.start').matcher, undefined)
  assert.equal(hooks.get('session.end').matcher, undefined)
  // Startup is covered by session.start and compaction keeps the session, so
  // neither may start a second collector.
  assert.deepEqual(hooks.get('classic.SessionStart').matcher, { source: ['clear', 'resume', 'fork'] })
  const started = await hooks.get('session.start').hook(f.engine, { cwd: '/project' }, async event => ({ cwd: event.cwd }))
  assert.deepEqual(started, { cwd: '/project' })
  await f.settle()
  const ended = await hooks.get('session.end').hook(f.engine, {}, async () => ({ sessionId: 'test' }))
  assert.deepEqual(ended, { sessionId: 'test' })
  assert.equal(f.timers[0].canceled, true)
})

test('the collector restarts after /clear, /resume, or /branch ends the session', async () => {
  for (const source of ['clear', 'resume', 'fork']) {
    const f = fixture(), hooks = registered()
    await hooks.get('session.start').hook(f.engine, { cwd: '/project' }, async event => event)
    await f.settle()
    assert.equal(f.requests.length, 2)
    await hooks.get('session.end').hook(f.engine, { reason: source === 'fork' ? 'resume' : source }, async event => event)
    assert.equal(f.timers[0].canceled, true)

    // No session.start follows; the settings SessionStart event does.
    const result = await hooks.get('classic.SessionStart').hook(f.engine, { source }, async event => ({ continued: event.source }))
    assert.deepEqual(result, { continued: source })
    await f.settle()
    assert.equal(f.requests.length, 4)
    assert.equal(f.timers.length, 2)
    assert.equal(f.timers[1].canceled, false)
    f.advance(5 * 60_000); f.tick(); await f.settle()
    assert.equal(f.requests.length, 6)
  }
})

test('a restart without a preceding session end still leaves one running collector', async () => {
  const f = fixture(), hooks = registered()
  await hooks.get('session.start').hook(f.engine, {}, async event => event)
  await f.settle()
  await hooks.get('classic.SessionStart').hook(f.engine, { source: 'resume' }, async event => event)
  await f.settle()
  assert.deepEqual(f.timers.map(timer => timer.canceled), [true, false])
  assert.equal(f.requests.length, 4)
  f.advance(5 * 60_000); f.tick(); await f.settle()
  // Only the replacement refreshes; the replaced collector never runs again.
  assert.equal(f.requests.length, 6)
})

const LEASE = `${DIRECTORY}/keep-alive.json`
const flush = () => new Promise(resolve => setImmediate(resolve))

/** One Claude session sharing the disk with others: its id, tool calls, and lease. */
function inSession(f, sessionID, files = new Map(), calls = []) {
  const write = f.engine.fs.write
  f.engine.fs.write = async (path, content) => { files.set(path, content); await write(path, content) }
  f.engine.fs.read = async path => {
    if (!files.has(path)) throw Object.assign(new Error('missing'), { code: 'ENOENT' })
    return files.get(path)
  }
  f.engine.session.id = async () => sessionID
  let started = 0
  f.engine.tool = { call: async input => {
    calls.push({ sessionID, ...input })
    if (input.tool !== 'Bash') return { result: { message: 'stopped', task_id: input.task_id, task_type: 'local_bash' } }
    return { result: { stdout: '', stderr: '', interrupted: false, backgroundTaskId: `${sessionID}-task-${++started}` } }
  } }
  return { files, calls, lease: () => files.has(LEASE) ? JSON.parse(files.get(LEASE)) : undefined }
}

test('a reporting collector holds one silent background task and renews its lease on each check', async () => {
  const f = fixture(), s = inSession(f, 'session-a'), collector = createUsageCollector(f.engine)
  await collector.start()
  assert.deepEqual(s.calls, [{
    sessionID: 'session-a', tool: 'Bash', command: KEEP_ALIVE_COMMAND,
    description: 'Keep Claude usage refreshing for usAIge', run_in_background: true,
  }])
  assert.deepEqual(s.lease(), { schemaVersion: 1, sessionID: 'session-a', renewedAt: '2026-10-14T00:00:00.000Z', taskID: 'session-a-task-1' })
  f.advance(30_000); f.tick(); await flush()
  assert.equal(s.calls.length, 1)
  assert.equal(s.lease().renewedAt, '2026-10-14T00:00:30.000Z')
  // Failed refreshes keep the task: retries continue only while the engine runs.
  f.engine.http.fetch = async () => response({}, 503)
  f.advance(5 * 60_000); f.tick(); await flush()
  assert.equal(s.calls.length, 1)
  assert.equal(s.lease().renewedAt, '2026-10-14T00:05:30.000Z')
  collector.stop(); await flush()
  assert.deepEqual(s.calls.at(-1), { sessionID: 'session-a', tool: 'TaskStop', task_id: 'session-a-task-1' })
  assert.deepEqual(s.lease(), { schemaVersion: 1, sessionID: 'session-a', renewedAt: '1970-01-01T00:00:00.000Z' })
})

test('only one session holds a task: another waits for the lease to expire, and the first then yields', async () => {
  const files = new Map(), calls = [], a = fixture(), b = fixture()
  inSession(a, 'session-a', files, calls)
  const s = inSession(b, 'session-b', files, calls)
  const first = createUsageCollector(a.engine), second = createUsageCollector(b.engine)
  await first.start(); await second.start()
  assert.deepEqual(calls.map(call => `${call.sessionID} ${call.tool}`), ['session-a Bash'])
  // Claude pauses the first session's engine, so nothing renews its lease.
  for (let i = 0; i < 3; i++) { b.advance(30_000); b.tick(); await flush() }
  assert.equal(calls.length, 1)
  b.advance(30_000); b.tick(); await flush()
  assert.deepEqual(calls.map(call => `${call.sessionID} ${call.tool}`), ['session-a Bash', 'session-b Bash'])
  // When the first engine runs again, it stops its own task and keeps out of the lease.
  a.advance(150_000); a.tick(); await flush()
  assert.deepEqual(calls.at(-1), { sessionID: 'session-a', tool: 'TaskStop', task_id: 'session-a-task-1' })
  assert.deepEqual(s.lease(), { schemaVersion: 1, sessionID: 'session-b', renewedAt: '2026-10-14T00:02:00.000Z', taskID: 'session-b-task-1' })
})

test('a session without a subscription never holds a task and releases one it held', async () => {
  const f = fixture(), s = inSession(f, 'session-a')
  f.engine.session.authorize = async () => ({ kind: 'api-key', handle: 'opaque-api-handle' })
  await createUsageCollector(f.engine).start()
  assert.deepEqual(s.calls, [])
  assert.equal(s.lease(), undefined)

  const g = fixture(), t = inSession(g, 'session-b')
  await createUsageCollector(g.engine).start()
  assert.equal(t.calls.length, 1)
  g.engine.session.authorize = async () => null
  g.advance(5 * 60_000); g.tick(); await flush()
  assert.deepEqual(t.calls.at(-1), { sessionID: 'session-b', tool: 'TaskStop', task_id: 'session-b-task-1' })
  assert.equal(t.lease().renewedAt, '1970-01-01T00:00:00.000Z')
})

test('a reloaded module adopts its session task, even while requests fail, instead of starting another', async () => {
  const files = new Map(), calls = [], before = fixture(), after = fixture()
  inSession(before, 'session-a', files, calls)
  await createUsageCollector(before.engine).start()
  // A hot reload drops the old module and its timers without session.end.
  const s = inSession(after, 'session-a', files, calls)
  after.advance(60_000)
  after.engine.http.fetch = async () => response({}, 429)
  await createUsageCollector(after.engine).start()
  assert.deepEqual(calls.map(call => call.tool), ['Bash'])
  assert.deepEqual(s.lease(), { schemaVersion: 1, sessionID: 'session-a', renewedAt: '2026-10-14T00:01:00.000Z', taskID: 'session-a-task-1' })
})

test('a session resumed after an unclean stop starts its own task instead of adopting its expired lease', async () => {
  const f = fixture(), s = inSession(f, 'session-a')
  // Claude was killed before session.end could stop the task or reset the lease.
  s.files.set(LEASE, JSON.stringify({ schemaVersion: 1, sessionID: 'session-a', renewedAt: '2026-10-13T23:57:59.000Z', taskID: 'stopped-engine-task' }))
  await createUsageCollector(f.engine).start()
  assert.deepEqual(s.calls.map(call => call.tool), ['Bash'])
  assert.deepEqual(s.lease(), { schemaVersion: 1, sessionID: 'session-a', renewedAt: '2026-10-14T00:00:00.000Z', taskID: 'session-a-task-1' })
  f.advance(30_000); f.tick(); await flush()
  assert.equal(s.calls.length, 1)
  assert.deepEqual(s.lease(), { schemaVersion: 1, sessionID: 'session-a', renewedAt: '2026-10-14T00:00:30.000Z', taskID: 'session-a-task-1' })
})

test('a refused keep-alive start never asks again until the session restarts', async () => {
  const refusals = [async () => ({ deny: 'Bash is not allowed here' }), async () => { throw new Error('denied') }]
  for (const refusal of refusals) {
    const f = fixture(), s = inSession(f, 'session-a'), call = f.engine.tool.call, hooks = registered()
    let refuse = true
    f.engine.tool.call = async input => {
      if (!refuse || input.tool !== 'Bash') return call(input)
      s.calls.push({ sessionID: 'session-a', ...input })
      return refusal()
    }
    await hooks.get('session.start').hook(f.engine, {}, async event => event)
    await flush()
    assert.equal(s.calls.length, 1)
    // Usage keeps refreshing for hours; the Bash call is never repeated.
    refuse = false
    for (let i = 0; i < 240; i++) { f.advance(30_000); f.tick(); await flush() }
    assert.equal(s.calls.length, 1)
    assert.equal(s.lease(), undefined)
    assert.equal(f.latest().observedAt, '2026-10-14T02:00:00.000Z')
    // /resume, /clear, or /branch restarts the collector, which may ask once more.
    await hooks.get('classic.SessionStart').hook(f.engine, { source: 'resume' }, async event => event)
    await flush()
    assert.deepEqual(s.calls.map(call => call.tool), ['Bash', 'Bash'])
    assert.equal(s.lease().taskID, 'session-a-task-1')
  }
})

test('a session that ends while its task starts stops that task', async () => {
  const f = fixture(), s = inSession(f, 'session-a'), call = f.engine.tool.call
  let release
  f.engine.tool.call = input => input.tool === 'Bash' ? new Promise(resolve => { release = () => resolve(call(input)) }) : call(input)
  const collector = createUsageCollector(f.engine), pending = collector.start()
  await flush()
  collector.stop()
  release(); await pending; await flush()
  assert.deepEqual(s.calls.map(call => call.tool), ['Bash', 'TaskStop'])
  assert.equal(s.lease(), undefined)
})

test('the keep-alive command stays silent while its parent lives and exits once orphaned', { skip: process.platform !== 'darwin' }, async () => {
  const wait = ms => new Promise(resolve => setTimeout(resolve, ms))
  for (const shell of ['/bin/sh', '/bin/zsh']) {
    const child = spawn(shell, ['-c', KEEP_ALIVE_COMMAND], { detached: true, env: {}, stdio: ['ignore', 'pipe', 'pipe'] })
    let output = '', exited = false
    child.stdout.on('data', data => { output += data })
    child.stderr.on('data', data => { output += data })
    child.on('exit', () => { exited = true })
    await wait(1_500)
    assert.equal(exited, false, shell)
    assert.equal(output, '', shell)
    process.kill(-child.pid, 'SIGKILL')
  }
  // The parent exits first; the shell then belongs to launchd and stops at its first check.
  const parent = spawn('/bin/sh', ['-c', '(/bin/sleep 0.5; exec /bin/sh -c "$KEEP") >/dev/null 2>&1 & echo $!'], {
    env: { KEEP: KEEP_ALIVE_COMMAND }, stdio: ['ignore', 'pipe', 'ignore'],
  })
  let pid = ''
  parent.stdout.on('data', data => { pid += data })
  await new Promise(resolve => parent.on('exit', resolve))
  await wait(2_000)
  assert.throws(() => process.kill(Number(pid.trim()), 0), { code: 'ESRCH' })
})

test('a collector restarted in the same session starts its own task instead of adopting the stopped one', async () => {
  const f = fixture(), s = inSession(f, 'session-a'), hooks = registered()
  await hooks.get('session.start').hook(f.engine, {}, async event => event)
  await flush()
  await hooks.get('classic.SessionStart').hook(f.engine, { source: 'resume' }, async event => event)
  await flush()
  assert.deepEqual(s.calls.map(call => call.task_id ? `${call.tool} ${call.task_id}` : call.tool), ['Bash', 'TaskStop session-a-task-1', 'Bash'])
  assert.equal(s.lease().taskID, 'session-a-task-2')
})
