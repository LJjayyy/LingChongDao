#!/usr/bin/env node
import assert from 'node:assert/strict'
import { test } from 'node:test'
import net from 'node:net'
import fs from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import crypto from 'node:crypto'
import vm from 'node:vm'
import { apply as installPlugin } from '../integrations/dsh-plugin/index.js'
import { installNavigation, validRequest, NAVIGATION_ROUTE, ATTENTION_ROUTE } from '../integrations/dsh-plugin/navigation.js'

const delay = ms => new Promise(resolve => setTimeout(resolve, ms))
const requestFor = sessionId => ({ version: 1, requestId: crypto.randomUUID(), sessionId })

test('Host forwards an exact manual view through the configured helper without conversation content', async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'dsh-view-helper-'))
  const helperPath = path.join(root, 'helper')
  const outputPath = path.join(root, 'events.jsonl')
  const routes = new Map()
  const disposers = []
  await fs.writeFile(helperPath, '#!/usr/bin/env node\n' +
    'let input = ""; process.stdin.on("data", chunk => input += chunk); process.stdin.on("end", () => require("node:fs").appendFileSync(' +
    JSON.stringify(outputPath) + ', input));\n', { mode: 0o700 })
  const ctx = {
    get: () => ({ fetch: { register: route => routes.set(route.path, route) } }),
    inject: (_names, factory) => factory(ctx), on: () => {},
    effect: factory => { const dispose = factory(); if (dispose) disposers.push(dispose) },
    logger: { warn: () => {} },
  }
  try {
    installPlugin(ctx, { helperPath, socketPath: path.join(root, 'bridge.sock'), navigationSocketPath: path.join(root, 'navigation.sock') })
    const viewedSince = Date.now() / 1000 - 2
    const response = await routes.get(ATTENTION_ROUTE).fetch(new Request(`http://localhost${ATTENTION_ROUTE}`, {
      method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ version: 1, sessionId: 'manual-A', viewedSince }),
    }))
    assert.equal(response.status, 200)
    let output
    const deadline = Date.now() + 1000
    while (!output && Date.now() < deadline) { output = await fs.readFile(outputPath, 'utf8').catch(() => ''); if (!output) await delay(10) }
    const event = JSON.parse(output)
    assert.equal(event.hook_event_name, 'SessionViewed')
    assert.equal(event.session_id, 'manual-A')
    assert.equal(event.viewed_since, viewedSince)
    assert.ok(event.timestamp >= viewedSince + 1)
    assert.deepEqual(Object.keys(event).sort(), ['hook_event_name', 'session_id', 'timestamp', 'viewed_since'])
  } finally {
    for (const dispose of disposers.reverse()) dispose()
    await delay(20)
    await fs.rm(root, { recursive: true, force: true })
  }
})
async function fixture(onViewed) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'dsh-nav-'))
  const socketPath = path.join(root, 'navigation.sock')
  const routes = new Map()
  const viewed = []
  const disposers = []
  const warnings = []
  installNavigation({
    get: () => ({ fetch: { register: value => { routes.set(value.path, value) } } }),
    effect: factory => { const disposer = factory(); if (disposer) disposers.push(disposer) },
    logger: { warn: warning => warnings.push(warning) },
  }, { navigationSocketPath: socketPath }, async value => { viewed.push(value); return onViewed?.(value) })
  for (let n = 0; n < 100; n++) { if ((await fs.stat(socketPath).catch(() => null))?.isSocket()) break; await delay(10) }
  assert.ok((await fs.stat(socketPath)).isSocket(), warnings.join('\n'))
  function send(request) {
    const socket = net.createConnection(socketPath)
    let output = ''
    const reply = new Promise((resolve, reject) => {
      socket.on('connect', () => socket.write(JSON.stringify(request) + '\n'))
      socket.on('error', reject)
      socket.on('data', bytes => { output += bytes; if (output.includes('\n')) resolve(JSON.parse(output.trim())) })
      socket.on('close', () => { if (!output) reject(new Error('closed-without-reply')) })
    })
    return { socket, reply }
  }
  const fetchRoute = (url = NAVIGATION_ROUTE, options = {}) => {
    const request = new Request(`http://localhost${url}`, options)
    return routes.get(new URL(request.url).pathname)?.fetch(request) ?? Promise.resolve(new Response(null, { status: 404 }))
  }
  return { root, socketPath, send, fetchRoute, viewed, close: async () => { for (const dispose of disposers.reverse()) dispose(); await delay(20); await fs.rm(root, { recursive: true, force: true }) } }
}

test('DSH navigation validates identity fields and bounded session IDs', () => {
  assert.equal(validRequest(requestFor('session-A')), true)
  for (const value of [{}, { ...requestFor('A'), version: 2 }, { ...requestFor('A'), requestId: 'not-uuid' }, requestFor(''), requestFor('A\nB'), requestFor('a'.repeat(1025))]) assert.equal(validRequest(value), false)
})

test('private socket delivers exact A/B identities; stale and wrong-session ACK cannot consume a request', async () => {
  const f = await fixture()
  try {
    assert.equal((await fs.stat(f.root)).mode & 0o777, 0o700)
    assert.equal((await fs.stat(f.socketPath)).mode & 0o777, 0o600)
    let sequence = 0
    let epoch = ''
    for (const id of ['A', 'B']) {
      const request = requestFor(id); const call = f.send(request)
      const frame = await (await f.fetchRoute(`${NAVIGATION_ROUTE}?after=${sequence}&epoch=${epoch}`)).json()
      if (!frame.command) { await delay(10); Object.assign(frame, await (await f.fetchRoute(`${NAVIGATION_ROUTE}?after=0`)).json()) }
      assert.deepEqual(frame.command, request); sequence = frame.sequence; epoch = frame.epoch
      const wrong = await f.fetchRoute(NAVIGATION_ROUTE, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ ...request, sessionId: 'wrong', status: 'opened' }) })
      assert.equal(wrong.status, 409)
      const ack = await f.fetchRoute(NAVIGATION_ROUTE, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ ...request, status: 'opened' }) })
      assert.equal(ack.status, 200)
      assert.deepEqual(await call.reply, { ...request, status: 'opened' })
      const cancelled = await (await f.fetchRoute(`${NAVIGATION_ROUTE}?after=${sequence}&epoch=${epoch}`)).json()
      assert.equal(cancelled.command, null); assert.ok(cancelled.sequence > sequence); sequence = cancelled.sequence
    }
  } finally { await f.close() }
})

test('new request supersedes old identity and disposal fails outstanding request', async () => {
  const f = await fixture()
  try {
    const a = f.send(requestFor('A'))
    await delay(20)
    const b = f.send(requestFor('B'))
    assert.equal((await a.reply).reason, 'superseded')
    await f.close()
    assert.equal((await b.reply).status, 'failed')
  } catch (error) { await f.close(); throw error }
})

test('invalid ACK content type, oversized and multi-frame socket input are refused', async () => {
  const f = await fixture()
  try {
    assert.equal((await f.fetchRoute(NAVIGATION_ROUTE, { method: 'POST', body: '{}' })).status, 415)
    for (const body of ['null', '[]', '1']) assert.equal((await f.fetchRoute(NAVIGATION_ROUTE, { method: 'POST', headers: { 'content-type': 'application/json' }, body })).status, 400)
    for (const bytes of ['x'.repeat(8193), JSON.stringify(requestFor('A')) + '\n{}\n']) {
      const socket = net.createConnection(f.socketPath)
      await new Promise((resolve, reject) => { socket.on('connect', () => socket.write(bytes)); socket.on('close', resolve); socket.on('error', reject) })
    }
  } finally { await f.close() }
})

const clientSource = await fs.readFile(new URL('../integrations/dsh-plugin/client.js', import.meta.url), 'utf8')
async function client(f, ready = true, baselineDelay = 0) {
  let plugin
  const rows = { A: { retainedBy: {} }, B: { retainedBy: {} } }
  let baselineReady = baselineDelay === 0
  if (!baselineReady) setTimeout(() => { baselineReady = true }, baselineDelay)
  const opened = []
  const disposers = []
  const states = { A: 'cold', B: 'cold' }
  let activePanelId = 'settings'
  let focused = true
  const document = new EventTarget()
  document.visibilityState = 'visible'
  document.hasFocus = () => focused
  const window = new EventTarget()
  window.__ModuleLoader__ = { load: registration => { plugin = registration.factory() } }
  const select = (id, state = 'open') => {
    for (const row of Object.values(rows)) row.retainedBy.mainView = 0
    if (id) { rows[id].retainedBy.mainView = 1; states[id] = state }
    activePanelId = null
  }
  const sandbox = {
    window, document,
    AbortController, setTimeout, clearTimeout, Date,
    requestAnimationFrame: callback => setTimeout(callback, 1), cancelAnimationFrame: clearTimeout,
    fetch: (url, options = {}) => f.fetchRoute(url, options),
  }
  vm.runInNewContext(clientSource, sandbox)
  plugin.apply({
    get: key => ({
      sessions: { list: { getSnapshot: () => ({ byId: baselineReady ? rows : {}, phase: baselineReady ? 'ready' : 'pending' }) }, binding: id => ({ session: { getSnapshot: () => ({ openState: states[id] }) } }) },
      uiWorkspace: { openSession: id => { opened.push(id); select(id, ready ? 'open' : 'error') } },
      layout: { panelInfo: { getSnapshot: () => ({ activePanelId }) } },
    })[key],
    effect: factory => { const dispose = factory(); if (dispose) disposers.push(dispose) },
  })
  return { opened, select, setPanel: id => { activePanelId = id }, setState: (id, state) => { states[id] = state },
    setRetained: (id, count) => { rows[id].retainedBy.mainView = count },
    setFocused: value => { focused = value; window.dispatchEvent(new Event(value ? 'focus' : 'blur')) },
    setVisible: value => { document.visibilityState = value ? 'visible' : 'hidden'; document.dispatchEvent(new Event('visibilitychange')) },
    close: () => disposers.forEach(dispose => dispose()) }
}

test('manually viewing a loaded DSH conversation reports only that session without island navigation', async () => {
  const f = await fixture(); const c = await client(f)
  try {
    c.select('A')
    const deadline = Date.now() + 1800
    while (!f.viewed.length && Date.now() < deadline) await delay(10)
    assert.equal(f.viewed[0]?.sessionId, 'A', 'a direct DSH visit must reach the island reminder acknowledgement path')
    assert.ok(Date.now() / 1000 - f.viewed[0].viewedSince >= 1, 'reading needs a full second of continuous attention')
    assert.ok(f.viewed.every(value => value.sessionId === 'A'), 'unopened B must remain unread')
    assert.deepEqual(c.opened, [], 'manual visits must never issue a navigation command')
  } finally { c.close(); await f.close() }
})

test('attention route validates dwell, exact identity and request bounds, and retries failed delivery', async () => {
  let result = false
  const f = await fixture(() => { if (result === 'throw') throw new Error('offline'); return result })
  const post = (value, options = {}) => f.fetchRoute(ATTENTION_ROUTE, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(value), ...options })
  const valid = () => ({ version: 1, sessionId: 'session-中-A', viewedSince: Date.now() / 1000 - 1.1 })
  try {
    assert.equal((await f.fetchRoute(ATTENTION_ROUTE)).status, 405)
    assert.equal((await post(valid(), { headers: {} })).status, 415)
    assert.equal((await post(valid(), { headers: { 'content-type': 'application/json', 'content-length': '8193' } })).status, 413)
    assert.equal((await post(valid(), { body: 'x'.repeat(8193) })).status, 413)
    for (const value of [null, [], {}, { ...valid(), version: 2 }, { ...valid(), sessionId: '' }, { ...valid(), sessionId: 'A\nB' },
      { ...valid(), sessionId: 'a'.repeat(1025) }, { ...valid(), viewedSince: '1' }, { ...valid(), viewedSince: null },
      { ...valid(), viewedSince: Date.now() / 1000 - 0.5 }, { ...valid(), viewedSince: Date.now() / 1000 + 1 },
      { ...valid(), viewedSince: Date.now() / 1000 - 61 }]) assert.equal((await post(value)).status, 400)
    assert.equal(f.viewed.length, 0, 'invalid views never reach the helper')
    assert.equal((await post(valid())).status, 503)
    await delay(300)
    result = 'throw'; assert.equal((await post(valid())).status, 503)
    await delay(300)
    result = true
    const payload = valid()
    const replies = await Promise.all(Array.from({ length: 32 }, () => post(payload)))
    assert.equal(replies.filter(reply => reply.status === 200).length, 1)
    assert.equal(replies.filter(reply => reply.status === 429).length, 31)
    assert.equal(f.viewed.length, 3, 'a burst of valid replays forwards only one view')
    assert.deepEqual(f.viewed.at(-1), payload)
  } finally { await f.close() }
})

test('manual attention ignores rapid switches and renews a sustained visit', async () => {
  const f = await fixture(); const c = await client(f)
  try {
    c.select('A'); await delay(300)
    c.select('B'); await delay(850)
    assert.equal(f.viewed.length, 0, 'time spent in A cannot count toward B')
    await delay(500)
    assert.equal(f.viewed[0]?.sessionId, 'B')
    const firstSince = f.viewed[0].viewedSince
    await delay(1150)
    assert.ok(f.viewed.length >= 2, 'a sustained visit must cover later completion and island restart')
    assert.ok(f.viewed.at(-1).viewedSince > firstSince)
    assert.ok(f.viewed.every(value => value.sessionId === 'B'))
  } finally { c.close(); await f.close() }
})

test('background, unfocused, settings, failed and ambiguous conversation views stay unread', async () => {
  const f = await fixture(); const c = await client(f)
  try {
    c.select('A'); c.setVisible(false); await delay(1100)
    c.setFocused(false); c.setVisible(true); await delay(1100)
    c.setPanel('settings'); c.setFocused(true); await delay(1100)
    c.setState('A', 'error'); c.setPanel(null); await delay(1100)
    c.setState('A', 'open'); c.setRetained('B', 1); await delay(1100)
    assert.equal(f.viewed.length, 0)
  } finally { c.close(); await f.close() }
})

test('losing focus resets dwell and disposed clients stop reporting', async () => {
  const f = await fixture(); const c = await client(f)
  try {
    c.select('A'); await delay(500)
    c.setFocused(false); await delay(20); c.setFocused(true)
    await delay(650)
    assert.equal(f.viewed.length, 0, 'the old dwell must be discarded on blur')
    await delay(600)
    assert.equal(f.viewed[0]?.sessionId, 'A')
    c.close()
    const count = f.viewed.length
    await delay(1100)
    assert.equal(f.viewed.length, count)
  } finally { c.close(); await f.close() }
})

test('manual attention retries a failed request without requiring another navigation', async () => {
  let delivered = false
  const f = await fixture(() => delivered)
  const c = await client(f)
  try {
    c.select('A'); await delay(1250)
    assert.equal(f.viewed.length, 1)
    delivered = true
    await delay(1150)
    assert.ok(f.viewed.length >= 2)
    assert.ok(f.viewed[1].viewedSince > f.viewed[0].viewedSince)
    assert.deepEqual(c.opened, [])
  } finally { c.close(); await f.close() }
})

test('a late attention response cannot reset the next conversation visit', async () => {
  const f = await fixture()
  let release
  const heldResponse = new Promise(resolve => { release = resolve })
  let held = false
  const c = await client({ fetchRoute: async (url, options) => {
    const response = await f.fetchRoute(url, options)
    if (url === ATTENTION_ROUTE && !held) { held = true; await heldResponse }
    return response
  } })
  try {
    c.select('A'); await delay(1250)
    assert.equal(f.viewed[0]?.sessionId, 'A')
    c.select('B'); await delay(1250)
    assert.equal(f.viewed[1]?.sessionId, 'B')
    await delay(750); release()
    await delay(500)
    assert.ok(f.viewed.filter(value => value.sessionId === 'B').length >= 2,
      'a delayed A response must not postpone B renewal')
  } finally { release(); c.close(); await f.close() }
})

test('browser bridge navigates A then B and acknowledges only a loaded main view', async () => {
  const f = await fixture(); const c = await client(f)
  try {
    for (const id of ['A', 'B']) assert.equal((await f.send(requestFor(id)).reply).status, 'opened')
    assert.deepEqual(c.opened, ['A', 'B'])
    assert.equal((await f.send(requestFor('missing')).reply).status, 'failed')
    assert.deepEqual(c.opened, ['A', 'B'])
  } finally { c.close(); await f.close() }
})

test('browser loading failure never returns opened', async () => {
  const f = await fixture(); const c = await client(f, false)
  try { assert.equal((await f.send(requestFor('A')).reply).status, 'failed') }
  finally { c.close(); await f.close() }
})


test('socket retains an exact Unicode session ID across split UTF-8 chunks', async () => {
  const f = await fixture()
  try {
    const request = requestFor('session-中-A')
    const bytes = Buffer.from(JSON.stringify(request) + '\n')
    const split = bytes.indexOf(Buffer.from('中')) + 1
    const socket = net.createConnection(f.socketPath)
    const reply = new Promise((resolve, reject) => { let output = ''; socket.on('data', data => { output += data; if (output.includes('\n')) resolve(JSON.parse(output.trim())) }); socket.on('error', reject) })
    await new Promise(resolve => socket.once('connect', resolve))
    socket.write(bytes.subarray(0, split)); await delay(10); socket.write(bytes.subarray(split))
    await delay(10)
    const frame = await (await f.fetchRoute()).json()
    assert.equal(frame.command.sessionId, request.sessionId)
    await f.fetchRoute(NAVIGATION_ROUTE, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ ...request, status: 'opened' }) })
    assert.equal((await reply).sessionId, request.sessionId)
  } finally { await f.close() }
})

test('client reconnects to a new Host epoch even when sequence restarts below its cursor', async () => {
  const first = await fixture(); const second = await fixture()
  let target = first
  const c = await client({ fetchRoute: (...args) => target.fetchRoute(...args) })
  try {
    assert.equal((await first.send(requestFor('A')).reply).status, 'opened')
    target = second
    await first.close()
    assert.equal((await second.send(requestFor('B')).reply).status, 'opened')
    assert.deepEqual(c.opened, ['A', 'B'])
  } finally { c.close(); await second.close() }
})

test('no client acknowledgement times out as failure', async () => {
  const f = await fixture()
  try { const reply = await f.send(requestFor('A')).reply; assert.equal(reply.status, 'failed'); assert.equal(reply.reason, 'timeout') }
  finally { await f.close() }
})


test('client waits for a cold-start Session list baseline before resolving an identity', async () => {
  const f = await fixture(); const c = await client(f, true, 100)
  try { assert.equal((await f.send(requestFor('A')).reply).status, 'opened'); assert.deepEqual(c.opened, ['A']) }
  finally { c.close(); await f.close() }
})
