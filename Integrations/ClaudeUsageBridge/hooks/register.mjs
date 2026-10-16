// Claude Code holds the existing sign-in. Only an opaque, host-owned handle
// reaches this module; it is never persisted or sent to any other host.
const API = 'https://api.anthropic.com/api/oauth'
const HEADERS = { 'anthropic-beta': 'oauth-2025-04-20' }
const CHECK_MS = 30_000
const REFRESH_MS = 5 * 60_000
const FAILURE_MS = 2 * 60_000
const RATE_LIMIT_MS = 15 * 60_000
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
// Claude Desktop neither idle-pauses nor memory-evicts a Code session while
// it runs a background task. One collecting session on this Mac holds such a
// task, named in a lease that every collector renews or respects.
const LEASE_MS = 2 * 60_000
// Silent, and never finishes while its engine runs: a finished task would wake
// the model. It exits only once its shell is orphaned, so no process outlives
// a Claude that was killed without stopping its tasks. An unreadable parent
// keeps it waiting. Absolute paths keep a changed PATH from making it spin.
export const KEEP_ALIVE_COMMAND = `until /bin/ps -o ppid= -p $$ | /usr/bin/grep -qx ' *1'; do /bin/sleep 60; done`
const KEEP_ALIVE_DESCRIPTION = 'Keep Claude usage refreshing for usAIge'
// Tasks a stopped collector is still stopping; a replacement in the same
// session must start its own rather than adopt one of these.
const releasing = new Set()

const record = value => value !== null && typeof value === 'object' && !Array.isArray(value)
const finite = value => typeof value === 'number' && Number.isFinite(value)
const percent = value => finite(value) && value >= 0 && value <= 100
const text = value => typeof value === 'string' ? value : undefined
const reset = value => value === null || (typeof value === 'string' &&
  /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/.test(value) && Number.isFinite(Date.parse(value)))

function fields(value, allowed) {
  if (!record(value)) return undefined
  const result = {}
  for (const [key, accepts] of Object.entries(allowed)) {
    if (accepts(value[key])) result[key] = value[key]
  }
  return result
}

function usageWindow(value) {
  if (value === null) return null
  return fields(value, {
    utilization: value => value === null || percent(value),
    resets_at: reset,
  })
}

function scope(value) {
  const result = fields(value, { display_name: value => typeof value === 'string', name: value => typeof value === 'string' })
  if (!result) return undefined
  for (const key of ['model', 'surface']) {
    const part = fields(value[key], { display_name: value => typeof value === 'string' })
    if (part && Object.keys(part).length) result[key] = part
  }
  return result
}

/** Keep only usage fields, excluding unknown fields at every retained level. */
export function filterUsage(value) {
  if (!record(value)) return null
  const result = {}
  if (Array.isArray(value.limits)) {
    // Modern limits are authoritative. A malformed nonempty list cannot be
    // silently downgraded to a valid-looking legacy reading.
    if (value.limits.some(limit => !record(limit) || !percent(limit.percent) || typeof limit.kind !== 'string' ||
      ('resets_at' in limit && !reset(limit.resets_at)))) return null
    result.limits = value.limits.flatMap(limit => {
      const entry = fields(limit, {
        kind: value => typeof value === 'string', group: value => typeof value === 'string',
        percent, severity: value => typeof value === 'string',
        resets_at: reset,
      })
      const selectedScope = scope(limit.scope)
      if (selectedScope && Object.keys(selectedScope).length) entry.scope = selectedScope
      return [entry]
    })
  }
  for (const [key, window] of Object.entries(value)) {
    if (!/^(five_hour|seven_day)(?:_[a-z0-9_]+)?$/.test(key)) continue
    if (record(window) && (('utilization' in window && window.utilization !== null && !percent(window.utilization)) ||
      ('resets_at' in window && !reset(window.resets_at)))) return null
    const selected = usageWindow(window)
    if (selected === null || selected && Object.keys(selected).length) result[key] = selected
  }
  const extra = fields(value.extra_usage, {
    is_enabled: value => typeof value === 'boolean',
    monthly_limit: value => value === null || finite(value),
    used_credits: finite, utilization: value => value === null || finite(value),
    currency: value => typeof value === 'string', decimal_places: finite,
    resets_at: reset,
  })
  if (extra && Object.keys(extra).length) result.extra_usage = extra
  const hasWindow = (result.limits?.length ?? 0) > 0 || Object.entries(result).some(([key, window]) =>
    /^(five_hour|seven_day)(?:_[a-z0-9_]+)?$/.test(key) && finite(window?.utilization))
  const windowless = Array.isArray(value.limits) && value.limits.length === 0 && value.five_hour === null && value.seven_day === null
  return hasWindow || windowless ? result : null
}

function retryDelay(response, now) {
  const header = text(response.headers?.['retry-after'])
  if (!header) return RATE_LIMIT_MS
  const seconds = Number(header)
  const delay = Number.isFinite(seconds) && seconds >= 0 ? seconds * 1000 : Date.parse(header) - now
  return Number.isFinite(delay) ? Math.max(RATE_LIMIT_MS, delay) : RATE_LIMIT_MS
}

/**
 * @param {import('claude-code').EngineInterface} $
 * No configuration, credential, cookie, transcript, or model access. The only
 * command is the keep-alive task, run through the session's own Bash tool.
 * HOME is the sole environment read: this SDK provides no home-directory API.
 */
export function createUsageCollector($) {
  let active = false
  let busy = false
  let nextAttemptAt = 0
  let directory
  let timer
  let generation = 0
  // True once this collector has reported, false without a subscription
  // session; undefined until either is known, which keeps but never starts a task.
  let canHold
  let holding = false
  let sessionID
  let keepAliveTaskID
  let keepAliveRefused = false

  async function writeStatus(state, reason, retryAt, current, organizationID) {
    if (!active || generation !== current || !directory) return
    const status = { schemaVersion: 1, checkedAt: new Date(await $.clock.now()).toISOString(), state }
    if (reason) status.reason = reason
    if (organizationID) status.organizationID = organizationID
    if (Number.isFinite(retryAt)) status.nextAttemptAt = new Date(retryAt).toISOString()
    await $.fs.write(`${directory}/status.json`, JSON.stringify(status))
  }

  async function refresh() {
    if (!active || busy) return
    busy = true
    const current = generation
    // Bound only by this attempt's profile. An earlier organization must not
    // survive a failed authorization or a failed profile request.
    let boundOrganizationID
    try {
      const now = await $.clock.now()
      if (now < nextAttemptAt || !active || generation !== current) return
      nextAttemptAt = now + REFRESH_MS
      if (!directory) {
        const home = await $.env.get('HOME')
        if (typeof home !== 'string' || !home.startsWith('/') || home.includes('\0')) return
        directory = `${home.replace(/\/$/, '')}/Library/Application Support/usAIge/claude-usage`
      }
      if (!active || generation !== current) return
      const auth = await $.session.authorize()
      if (!active || generation !== current) return
      if (auth?.kind !== 'bearer' || typeof auth.handle !== 'string' || !auth.handle) {
        nextAttemptAt = now + FAILURE_MS
        canHold = false
        await writeStatus('unavailable', 'no_subscription_session', nextAttemptAt, current)
        return
      }
      await writeStatus('refreshing', undefined, nextAttemptAt, current)
      if (!active || generation !== current) return
      // Rebind on every refresh: never attach another account's figures to an
      // organization remembered from an earlier session or an earlier reading.
      const profile = await $.http.fetch(`${API}/profile`, { method: 'GET', headers: HEADERS, auth: auth.handle })
      if (!active || generation !== current) return
      if (!profile.ok) {
        const at = await $.clock.now()
        nextAttemptAt = at + (profile.status === 429 ? retryDelay(profile, at) : FAILURE_MS)
        await writeStatus('error', profile.status === 429 ? 'rate_limited' : 'profile_request_failed', nextAttemptAt, current)
        return
      }
      const organizationID = JSON.parse(profile.text)?.organization?.uuid
      if (typeof organizationID !== 'string' || !UUID.test(organizationID)) throw new Error('invalid_organization')
      boundOrganizationID = organizationID.toLowerCase()
      await writeStatus('refreshing', undefined, nextAttemptAt, current, boundOrganizationID)
      if (!active || generation !== current) return
      const response = await $.http.fetch(`${API}/usage`, { method: 'GET', headers: HEADERS, auth: auth.handle })
      if (!active || generation !== current) return
      if (!response.ok) {
        const at = await $.clock.now()
        nextAttemptAt = at + (response.status === 429 ? retryDelay(response, at) : FAILURE_MS)
        await writeStatus('error', response.status === 429 ? 'rate_limited' : 'usage_request_failed', nextAttemptAt, current, boundOrganizationID)
        return
      }
      const usage = filterUsage(JSON.parse(response.text))
      if (!usage) throw new Error('invalid_usage')
      const observedAt = await $.clock.now()
      if (!active || generation !== current) return
      // SDK fs.write creates parent directories but provides no rename API.
      // Readers must reject incomplete JSON and retry their next local read.
      await $.fs.write(`${directory}/response.json`, JSON.stringify({
        schemaVersion: 1, observedAt: new Date(observedAt).toISOString(),
        organizationID: boundOrganizationID, usage,
      }))
      nextAttemptAt = observedAt + REFRESH_MS
      canHold = true
      // The response is already current. A status-write failure must not
      // shorten the successful network request's five-minute floor.
      await writeStatus('ready', undefined, nextAttemptAt, current, boundOrganizationID).catch(() => {})
    } catch {
      if (!active || generation !== current) return
      nextAttemptAt = (await $.clock.now()) + FAILURE_MS
      // Only a fixed reason is shared. Neither exception messages, server
      // bodies, profile data, nor opaque authorization handles are recorded.
      await writeStatus('error', 'refresh_failed', nextAttemptAt, current, boundOrganizationID).catch(() => {})
    } finally {
      busy = false
    }
  }

  async function readLease() {
    try {
      const lease = JSON.parse(await $.fs.read(`${directory}/keep-alive.json`))
      const renewedAt = Date.parse(lease?.renewedAt)
      if (lease?.schemaVersion !== 1 || typeof lease.sessionID !== 'string' || !Number.isFinite(renewedAt)) return undefined
      return { sessionID: lease.sessionID, taskID: typeof lease.taskID === 'string' ? lease.taskID : undefined, renewedAt }
    } catch {
      return undefined
    }
  }

  function writeLease(taskID, renewedAt) {
    const lease = { schemaVersion: 1, sessionID, renewedAt: new Date(renewedAt).toISOString() }
    if (taskID) lease.taskID = taskID
    return $.fs.write(`${directory}/keep-alive.json`, JSON.stringify(lease))
  }

  /** TaskStop ends the task without notifying the model, unlike its exit. */
  async function release(taskID) {
    releasing.add(taskID)
    try {
      await $.tool.call({ tool: 'TaskStop', task_id: taskID }).catch(() => {})
      const lease = await readLease()
      if (lease?.sessionID === sessionID && (!lease.taskID || lease.taskID === taskID)) await writeLease(undefined, 0)
    } finally {
      releasing.delete(taskID)
    }
  }

  /** Hold, renew, adopt after a module reload, or yield the session's task. */
  async function hold() {
    if (!active || holding || !directory) return
    holding = true
    const current = generation
    try {
      sessionID ??= await $.session.id()
      const now = await $.clock.now()
      if (!active || generation !== current || typeof sessionID !== 'string' || !sessionID) return
      const lease = await readLease()
      if (!active || generation !== current) return
      const ours = lease?.sessionID === sessionID
      const live = lease !== undefined && Math.abs(now - lease.renewedAt) < LEASE_MS
      if (!keepAliveTaskID && ours && !releasing.has(lease.taskID)) keepAliveTaskID = lease.taskID
      if (canHold === false || (live && !ours)) {
        const taskID = keepAliveTaskID
        keepAliveTaskID = undefined
        if (taskID) await release(taskID)
        return
      }
      if (!keepAliveTaskID) {
        if (canHold !== true || keepAliveRefused) return
        const ran = await $.tool.call({
          tool: 'Bash', command: KEEP_ALIVE_COMMAND, description: KEEP_ALIVE_DESCRIPTION, run_in_background: true,
        }).catch(() => undefined)
        const taskID = ran?.result?.backgroundTaskId
        if (typeof taskID !== 'string' || !taskID) {
          // Another start would ask again. A denied or failed start waits for
          // the session to restart, which creates a new collector.
          keepAliveRefused = true
          return
        }
        if (!active || generation !== current) {
          await release(taskID)
          return
        }
        keepAliveTaskID = taskID
      }
      await writeLease(keepAliveTaskID, now)
    } catch {
      // The next check reads the lease again.
    } finally {
      holding = false
    }
  }

  async function tick() {
    await refresh()
    await hold()
  }

  return {
    start() {
      timer?.cancel()
      active = true
      generation += 1
      nextAttemptAt = 0
      timer = $.clock.every(CHECK_MS, () => { void tick().catch(() => {}) })
      return tick()
    },
    stop() {
      active = false
      generation += 1
      timer?.cancel()
      timer = undefined
      const taskID = keepAliveTaskID
      keepAliveTaskID = undefined
      if (taskID) void release(taskID).catch(() => {})
    },
    refresh,
    hold,
  }
}

/** Stop the previous collector, if any, and start one for this session. */
function restartCollector($, previous) {
  previous?.stop()
  const collector = createUsageCollector($)
  void collector.start().catch(() => {})
  return collector
}

/** @type {import('claude-code').Register} */
export function register(on) {
  let collector
  on('session.start', async ($, event, next) => {
    const started = await next(event)
    collector = restartCollector($, collector)
    return started
  })
  // /clear, /resume, and /branch end the session without a new session.start.
  // The settings SessionStart event follows each of them (/branch reports fork).
  // Restarting first keeps a later handler's failure from stopping collection.
  on('classic.SessionStart', { source: ['clear', 'resume', 'fork'] }, ($, event, next) => {
    collector = restartCollector($, collector)
    return next(event)
  })
  on('session.end', ($, event, next) => {
    collector?.stop()
    return next(event)
  })
}
