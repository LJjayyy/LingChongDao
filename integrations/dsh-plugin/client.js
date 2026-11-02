/* MIT License — Copyright (c) 2026 LJjayyy. See LICENSE.
 * DSH's documented factory-form browser bundle; no external runtime packages. */
window.__ModuleLoader__.load({
  id: 'lingchongdao-dsh-hooks',
  factory: () => {
    const route = '/api/lingchongdao/navigation'
    const inject = ['uiWorkspace', 'sessions', 'layout']
    function apply(ctx) {
      const lifetime = new AbortController()
      let navigation
      let sequence = 0
      let epoch = ''
      const sessions = ctx.get('sessions')
      const workspace = ctx.get('uiWorkspace')
      const layout = ctx.get('layout')
      const sleep = (ms, signal) => new Promise((resolve, reject) => {
        const abort = () => { clearTimeout(timer); reject(signal.reason) }
        const timer = setTimeout(() => { signal.removeEventListener('abort', abort); resolve() }, ms)
        signal.addEventListener('abort', abort, { once: true })
        if (signal.aborted) abort()
      })
      async function deliver(command, signal) {
        let status = 'failed'
        try {
          const deadline = Date.now() + 3500
          while (!sessions.list.getSnapshot().byId[command.sessionId]) {
            signal.throwIfAborted()
            if (sessions.list.getSnapshot().phase === 'ready' || Date.now() >= deadline) throw new Error('missing-session')
            await sleep(40, signal)
          }
          signal.throwIfAborted()
          workspace.openSession(command.sessionId)
          while (!signal.aborted && Date.now() < deadline) {
            const row = sessions.list.getSnapshot().byId[command.sessionId]
            const snapshot = sessions.binding(command.sessionId)?.session.getSnapshot()
            if (snapshot?.openState === 'error') throw new Error('open-failed')
            if ((row?.retainedBy?.mainView || 0) > 0 && snapshot?.openState === 'open') {
              // UiWorkspace exclusively owns mainView. Require its selected,
              // loaded Conversation to remain stable; background RAF is throttled
              // and cannot provide a reliable navigation acknowledgement.
              await sleep(60, signal)
              if (signal.aborted) return
              const selected = sessions.list.getSnapshot().byId[command.sessionId]
              const ready = sessions.binding(command.sessionId)?.session.getSnapshot().openState === 'open'
              if (ready && (selected?.retainedBy?.mainView || 0) > 0 && layout.panelInfo?.getSnapshot?.().activePanelId === null) {
                status = 'opened'; break
              }
            }
            await sleep(40, signal)
          }
        } catch { /* An unsuccessful open never consumes a reminder. */ }
        if (signal.aborted) return
        await fetch(route, { method: 'POST', headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ ...command, status }), signal: lifetime.signal, credentials: 'same-origin' })
      }
      async function poll() {
        let backoff = 250
        while (!lifetime.signal.aborted) {
          try {
            const response = await fetch(`${route}?after=${sequence}&epoch=${encodeURIComponent(epoch)}`, { signal: lifetime.signal, cache: 'no-store', credentials: 'same-origin' })
            if (!response.ok) throw new Error('navigation-route-unavailable')
            const frame = await response.json()
            if (frame.version !== 1 || typeof frame.epoch !== 'string' || !Number.isSafeInteger(frame.sequence)) throw new Error('invalid-frame')
            if (frame.epoch !== epoch || frame.sequence > sequence) {
              epoch = frame.epoch
              sequence = frame.sequence
              navigation?.abort()
              navigation = new AbortController()
              if (frame.command) void deliver(frame.command, navigation.signal).catch(() => {})
            }
            backoff = 250
          } catch {
            if (lifetime.signal.aborted) return
            await sleep(backoff, lifetime.signal).catch(() => {})
            backoff = Math.min(backoff * 2, 10000)
          }
        }
      }
      ctx.effect(() => {
        void poll()
        return () => { lifetime.abort(); navigation?.abort() }
      }, 'lingchongdao-hooks: navigation client')
    }
    return { inject, apply }
  },
})
