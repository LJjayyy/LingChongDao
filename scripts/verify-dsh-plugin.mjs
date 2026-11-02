#!/usr/bin/env node
import assert from 'node:assert/strict'
import { test } from 'node:test'
import net from 'node:net'
import fs from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import crypto from 'node:crypto'
import vm from 'node:vm'
import { installNavigation, validRequest, NAVIGATION_ROUTE } from '../integrations/dsh-plugin/navigation.js'

const delay = ms => new Promise(resolve => setTimeout(resolve, ms))
const requestFor = sessionId => ({ version: 1, requestId: crypto.randomUUID(), sessionId })
async function fixture() {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'dsh-nav-'))
  const socketPath = path.join(root, 'navigation.sock')
  let route
  const disposers = []
  const warnings = []
  installNavigation({
    get: () => ({ fetch: { register: value => { route = value } } }),
    effect: factory => { const disposer = factory(); if (disposer) disposers.push(disposer) },
    logger: { warn: warning => warnings.push(warning) },
  }, { navigationSocketPath: socketPath })
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
  const fetchRoute = (url = NAVIGATION_ROUTE, options = {}) => route.fetch(new Request(`http://localhost${url}`, options))
  return { root, socketPath, send, fetchRoute, close: async () => { for (const dispose of disposers.reverse()) dispose(); await delay(20); await fs.rm(root, { recursive: true, force: true }) } }
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
  const sandbox = {
    window: { __ModuleLoader__: { load: registration => { plugin = registration.factory() } } },
    AbortController, setTimeout, clearTimeout, Date,
    requestAnimationFrame: callback => setTimeout(callback, 1), cancelAnimationFrame: clearTimeout,
    fetch: (url, options = {}) => f.fetchRoute(url, options),
  }
  vm.runInNewContext(clientSource, sandbox)
  plugin.apply({
    get: key => ({
      sessions: { list: { getSnapshot: () => ({ byId: baselineReady ? rows : {}, phase: baselineReady ? 'ready' : 'pending' }) }, binding: id => ({ session: { getSnapshot: () => ({ openState: states[id] }) } }) },
      uiWorkspace: { openSession: id => { opened.push(id); for (const row of Object.values(rows)) row.retainedBy.mainView = 0; rows[id].retainedBy.mainView = 1; states[id] = ready ? 'open' : 'error'; activePanelId = null } },
      layout: { panelInfo: { getSnapshot: () => ({ activePanelId }) } },
    })[key],
    effect: factory => { const dispose = factory(); if (dispose) disposers.push(dispose) },
  })
  return { opened, close: () => disposers.forEach(dispose => dispose()) }
}

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
