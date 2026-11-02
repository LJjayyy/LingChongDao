/* MIT License — Copyright (c) 2026 LJjayyy. See LICENSE. */
import net from 'node:net'
import fs from 'node:fs/promises'
import path from 'node:path'
import { randomUUID } from 'node:crypto'

export const NAVIGATION_ROUTE = '/api/lingchongdao/navigation'
const DEADLINE_MS = 4000
const MAX_BYTES = 8192

/** Local requests use a private Unix socket; browser delivery uses DSH's
 * authenticated, owner-only exact Fetch-route registry. No Host token escapes. */
export function installNavigation(ctx, config = {}) {
  const connection = ctx.get?.('connection')
  if (typeof connection?.fetch?.register !== 'function') {
    ctx.logger?.warn?.('lingchongdao-hooks: this Harness version has no navigation Fetch-route capability')
    return
  }
  const home = process.env.HOME || ''
  const socketPath = config.navigationSocketPath || (home && path.join(home, 'Library/Application Support/LingChongDao/run/dsh-navigation.sock'))
  if (!socketPath) return
  let disposed = false
  let pending
  let sequence = 0
  const epoch = randomUUID()
  const waiters = new Set()
  const clients = new Set()
  const server = net.createServer(socket => {
    if (disposed || clients.size >= 16) { socket.destroy(); return }
    clients.add(socket)
    socket.on('error', () => {})
    socket.on('close', () => { clients.delete(socket); if (pending?.socket === socket) finish('failed', 'disconnected') })
    socket.setTimeout(DEADLINE_MS + 250, () => socket.destroy())
    let input = Buffer.alloc(0)
    let received = false
    socket.on('data', chunk => {
      if (received) { socket.destroy(); return }
      input = Buffer.concat([input, chunk])
      if (input.length > MAX_BYTES) { socket.destroy(); return }
      const newline = input.indexOf(10)
      if (newline < 0) return
      received = true
      if (input.subarray(newline + 1).toString('utf8').trim()) { socket.destroy(); return }
      let request
      try { request = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(input.subarray(0, newline))) } catch { socket.destroy(); return }
      if (!validRequest(request)) { socket.destroy(); return }
      if (pending) finish('failed', 'superseded')
      const timer = setTimeout(() => finish('failed', 'timeout'), DEADLINE_MS)
      pending = { request, socket, timer, sequence: ++sequence }
      wake()
    })
  })
  server.on('error', error => ctx.logger?.warn?.(`lingchongdao-hooks: navigation unavailable (${error.code || 'socket'})`))

  function finish(status, reason) {
    const current = pending
    if (!current) return
    pending = undefined
    sequence++
    clearTimeout(current.timer)
    const reply = { ...current.request, status, ...(reason ? { reason } : {}) }
    if (!current.socket.destroyed) current.socket.end(JSON.stringify(reply) + '\n')
    wake()
  }
  function envelope() {
    return { version: 1, epoch, sequence, command: pending ? pending.request : null }
  }
  function wake() { for (const resolve of [...waiters]) resolve() }
  function json(value, status = 200) { return new Response(JSON.stringify(value), { status, headers: { 'content-type': 'application/json', 'cache-control': 'no-store' } }) }

  connection.fetch.register({
    path: NAVIGATION_ROUTE, methods: ['GET', 'POST'], requestBody: 'buffered',
    async fetch(request) {
      if (disposed) return json({ error: 'disposed' }, 503)
      if (request.method === 'POST') {
        if (!/^application\/json(?:\s*;|$)/i.test(request.headers.get('content-type') || '')) return json({ error: 'content-type' }, 415)
        if (Number(request.headers.get('content-length') || 0) > MAX_BYTES) return json({ error: 'too-large' }, 413)
        const body = await request.text()
        if (Buffer.byteLength(body) > MAX_BYTES) return json({ error: 'too-large' }, 413)
        let ack
        try { ack = JSON.parse(body) } catch { return json({ error: 'invalid' }, 400) }
        if (ack === null || typeof ack !== 'object' || Array.isArray(ack)) return json({ error: 'invalid' }, 400)
        const active = pending?.request
        if (!active || ack.version !== 1 || ack.requestId !== active.requestId || ack.sessionId !== active.sessionId) return json({ error: 'stale' }, 409)
        if (ack.status !== 'opened' && ack.status !== 'failed') return json({ error: 'invalid' }, 400)
        finish(ack.status, ack.status === 'failed' ? 'navigation-failed' : undefined)
        return json({ ok: true })
      }
      const query = new URL(request.url).searchParams
      const after = Number(query.get('after') || 0)
      if (!Number.isSafeInteger(after) || after < 0) return json({ error: 'invalid' }, 400)
      if (query.get('epoch') !== epoch || sequence > after || disposed) return json(envelope())
      if (waiters.size >= 4) return json({ error: 'busy' }, 429)
      await new Promise(resolve => {
        let timer
        const done = () => { clearTimeout(timer); waiters.delete(done); request.signal.removeEventListener('abort', done); resolve() }
        waiters.add(done)
        request.signal.addEventListener('abort', done, { once: true })
        timer = setTimeout(done, 20000)
        if (request.signal.aborted) done()
      })
      return json(envelope())
    },
  })

  // Never remove an existing live listener. A stale socket may be reclaimed
  // only when it is a socket owned by this uid and connect refuses it.
  async function listen() {
    await fs.mkdir(path.dirname(socketPath), { recursive: true, mode: 0o700 })
    const directory = await fs.lstat(path.dirname(socketPath))
    if (!directory.isDirectory() || directory.uid !== process.getuid?.()) throw new Error('unsafe-socket-directory')
    await fs.chmod(path.dirname(socketPath), 0o700)
    try {
      const entry = await fs.lstat(socketPath)
      if (!entry.isSocket() || entry.uid !== process.getuid?.()) throw new Error('unsafe-existing-path')
      const live = await new Promise(resolve => {
        const probe = net.createConnection(socketPath)
        probe.on('connect', () => { probe.destroy(); resolve(true) })
        probe.on('error', error => { probe.destroy(); resolve(error.code !== 'ECONNREFUSED' && error.code !== 'ENOENT') })
        probe.setTimeout(250, () => { probe.destroy(); resolve(true) })
      })
      if (live) throw new Error('listener-already-active')
      const current = await fs.lstat(socketPath)
      if (current.ino !== entry.ino || current.dev !== entry.dev) throw new Error('socket-path-changed')
      await fs.unlink(socketPath).catch(error => { if (error.code !== 'ENOENT') throw error })
    } catch (error) { if (error.code !== 'ENOENT') throw error }
    if (disposed) return
    await new Promise((resolve, reject) => {
      server.once('error', reject)
      server.listen(socketPath, () => { server.removeListener('error', reject); resolve() })
    })
    if (disposed) { server.close(); return }
    await fs.chmod(socketPath, 0o600)
  }
  void listen().catch(error => ctx.logger?.warn?.(`lingchongdao-hooks: navigation unavailable (${error.code || error.message})`))
  ctx.effect(() => () => {
    disposed = true
    finish('failed', 'disposed')
    wake()
    for (const socket of clients) socket.destroy()
    server.close()
  }, 'lingchongdao-hooks: navigation bridge')
}

export function validRequest(value) {
  return value?.version === 1 && typeof value.requestId === 'string'
    && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value.requestId)
    && typeof value.sessionId === 'string' && value.sessionId.length > 0 && value.sessionId.length <= 1024
    && !/[\u0000-\u001f\u007f]/.test(value.sessionId)
}
