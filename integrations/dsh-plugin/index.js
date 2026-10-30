/*
MIT License

Copyright (c) 2026 LJjayyy

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

This license covers this JavaScript code. Artwork is excluded; see NOTICE.md.
The full notice stays in this file because the DSH installer copies runtime files.
*/
/**
 * 灵宠岛 · DeepSeek Harness 观测插件
 *
 * Mounted by one loader row in `~/.dsh/profiles/desktop/cordis.patch.yml`:
 *
 *   - insert:
 *       - id: lingchongdao-hooks
 *         name: 'lingchongdao-dsh-hooks'
 *         config:
 *           helperPath: '<Application Support>/LingChongDao/bin/lingchongdao-hook'
 *           socketPath: '<Application Support>/LingChongDao/run/bridge.sock'
 *
 * It is observation-only: every event is turned into the Claude Code payload
 * shape that `lingchongdao-hook` already normalizes, written to the helper's
 * stdin, and the result is discarded. Sessions are never blocked, steered or
 * approved from here, which is why no decision is returned to the harness.
 */

import { spawn } from 'node:child_process'

export const name = 'lingchongdao-hooks'
/** No harness service is needed: the helper is spawned directly. */
export const inject = []

/** Bounds a hung helper so the plugin can never keep a child alive forever. */
const HELPER_KILL_MS = 1500

export function apply(ctx, config) {
  // The bundle mounts this row without config; the stable install locations are
  // derived from the home directory so a profile needs no per-install setup.
  const home = typeof process.env.HOME === 'string' ? process.env.HOME : ''
  const helperPath = typeof config?.helperPath === 'string' && config.helperPath
    ? config.helperPath
    : home ? `${home}/Library/Application Support/LingChongDao/bin/lingchongdao-hook` : ''
  const socketPath = typeof config?.socketPath === 'string' && config.socketPath
    ? config.socketPath
    : home ? `${home}/Library/Application Support/LingChongDao/run/bridge.sock` : ''
  if (!helperPath || !socketPath) {
    ctx.logger?.warn?.('lingchongdao-hooks: helperPath and socketPath are required; no island events will be sent')
    return
  }

  const running = new Set()
  // The harness emits session-start while boot is still settling, so a plugin
  // mounted from the profile can miss it. Remembering announced sessions lets the
  // first prompt announce the session instead of losing the beginning.
  const started = new Set()
  ctx.effect?.(() => () => {
    for (const child of running) {
      try { child.kill('SIGKILL') } catch {}
    }
    running.clear()
  }, 'lingchongdao-hooks: stop pending helpers')

  function sessionID(agent) {
    const header = agent?.session?.header
    return typeof header?.id === 'string' ? header.id : ''
  }

  /** Returns true only for the first sighting of a session. */
  function announceOnce(agent) {
    const id = sessionID(agent)
    if (!id || started.has(id)) return false
    if (started.size >= 256) started.clear()
    started.add(id)
    return true
  }

  /** Flatten harness content blocks to plain text (the helper only needs text). */
  function text(content) {
    if (typeof content === 'string') return content
    if (!Array.isArray(content)) return ''
    return content
      .filter((block) => block?.type === 'text' && typeof block.text === 'string')
      .map((block) => block.text)
      .join('')
  }

  function base(agent, event) {
    const header = agent?.session?.header
    return {
      session_id: sessionID(agent),
      hook_event_name: event,
      cwd: typeof header?.cwd === 'string' ? header.cwd : process.cwd(),
    }
  }

  /** Fire-and-forget: the island is an observer, never part of the decision path. */
  function send(payload) {
    if (!payload.session_id) return
    let child
    try {
      child = spawn(helperPath, ['--provider', 'dsh', '--socket', socketPath, '--timeout', '2'],
                    { stdio: ['pipe', 'ignore', 'ignore'] })
    } catch (error) {
      ctx.logger?.warn?.(`lingchongdao-hooks: cannot start helper: ${String(error)}`)
      return
    }
    running.add(child)
    const timer = setTimeout(() => {
      try { child.kill('SIGKILL') } catch {}
    }, HELPER_KILL_MS)
    const settle = () => { clearTimeout(timer); running.delete(child) }
    child.on('close', settle)
    child.on('error', (error) => {
      settle()
      ctx.logger?.warn?.(`lingchongdao-hooks: helper failed: ${String(error)}`)
    })
    child.stdin?.on('error', () => {})
    try { child.stdin?.end(JSON.stringify(payload) + '\n') } catch {}
    child.unref?.()
  }

  ctx.on('agent/session-start', ({ agent, source } = {}) => {
    if (!announceOnce(agent)) return
    send({ ...base(agent, 'SessionStart'), source: typeof source === 'string' ? source : 'startup' })
  })

  // The harness re-enters this point for every step; only a real user message is
  // a prompt submission, so tool results and injected context never rename tasks.
  ctx.on('agent/pre-step', ({ agent, messages } = {}, next) => {
    if (announceOnce(agent)) {
      send({ ...base(agent, 'SessionStart'), source: 'startup' })
    }
    const prompts = Array.isArray(messages) ? messages.filter((message) => message?.source?.kind === 'user') : []
    if (prompts.length > 0) {
      send({ ...base(agent, 'UserPromptSubmit'), prompt: text(prompts.flatMap((message) => message?.content ?? [])) })
    }
    return next()
  })

  ctx.on('tools/pre-execute', (exec, next) => {
    send({
      ...base(exec?.agent, 'PreToolUse'),
      tool_name: exec?.name,
      tool_input: exec?.arguments,
      tool_use_id: exec?.callId,
    })
    return next()
  })

  ctx.on('tools/post-execute', (exec, result, next) => {
    send({
      ...base(exec?.agent, 'PostToolUse'),
      tool_name: exec?.name,
      tool_input: exec?.arguments,
      tool_use_id: exec?.callId,
      tool_response: text(result?.content),
    })
    return next()
  })

  ctx.on('agent/turn-stopping', ({ agent } = {}) => {
    send({ ...base(agent, 'Stop'), stop_hook_active: false })
  })

  ctx.on('subagent/start', (info = {}) => {
    const child = ctx.get?.('agents')?.get?.(info.id)
    send({ ...base(child, 'SubagentStart'), agent_id: info.id, agent_type: 'general-purpose' })
  })

  ctx.on('subagent/end', (info = {}) => {
    const child = ctx.get?.('agents')?.get?.(info.id)
    send({ ...base(child, 'SubagentStop'), agent_id: info.id, agent_type: 'general-purpose', stop_hook_active: false })
  })
}
