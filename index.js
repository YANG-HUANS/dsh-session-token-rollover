/**
 * Session token rollover (`@local/session-token-rollover`).
 *
 * When a conversation's token budget is exhausted — either the measured request
 * pressure crosses the configured threshold, or the model ends a turn with the
 * `max-tokens` finish reason — this Host plugin opens a NEW Session that inherits
 * the content of the finished one.
 *
 * Two inheritance modes:
 *   - `digest` (default): a fresh Session is created and seeded with a handoff
 *     message built from the tail of the previous conversation, so the new
 *     Session starts with a healthy token budget instead of an exhausted one.
 *   - `fork`: the new Session is a full fork of the previous log (zero model
 *     cost, but it carries the same context pressure).
 *
 * Every registration is owned by this plugin's fiber, so unloading the plugin
 * removes the listener.
 */

/** Services this plugin cannot work without. */
export const inject = ['tokenMeter', 'sessionController']

/** Turn-end reasons that must never trigger a rollover. */
const IGNORED_TURN_END = new Set(['aborted', 'forked'])

const DEFAULT_OPTIONS = {
  /** Master switch. */
  enabled: true,
  /** `digest` builds a handoff message; `fork` copies the whole event prefix. */
  mode: 'digest',
  /** Absolute token threshold. `0` means "derive it from the model context window". */
  maxTokens: 0,
  /** Fraction of the model context window used when `maxTokens` is `0`. */
  ratio: 0.85,
  /** Threshold used when neither `maxTokens` nor a context window is known. */
  fallbackLimitTokens: 100000,
  /** Also roll over when a turn ends with the `max-tokens` finish reason. */
  onMaxTokens: true,
  /** Whether subagent sessions may roll over. */
  allowSubagent: false,
  /** How many recent user/assistant messages the handoff message carries. */
  keepRecent: 8,
  /** Per-message character cap inside the handoff message. */
  maxCharsPerMessage: 500,
  /** Total character cap for the handoff message body. */
  maxTotalChars: 6000,
  /** Send the handoff message into the new Session (starts one model turn). */
  autoPrompt: true,
}

/**
 * Validate and fill defaults for the Loader row `config`.
 * @param {Record<string, unknown> | undefined} raw - configured values.
 * @returns {typeof DEFAULT_OPTIONS} resolved options.
 */
function normalizeOptions(raw) {
  const source = raw !== null && typeof raw === 'object' ? raw : {}
  const bool = (key) => (typeof source[key] === 'boolean' ? source[key] : DEFAULT_OPTIONS[key])
  const num = (key, min) => {
    const value = Number(source[key])
    return Number.isFinite(value) && value >= min ? value : DEFAULT_OPTIONS[key]
  }
  return {
    enabled: bool('enabled'),
    mode: source.mode === 'fork' ? 'fork' : 'digest',
    maxTokens: Math.floor(num('maxTokens', 0)),
    ratio: Math.min(1, num('ratio', 0.05)),
    fallbackLimitTokens: Math.floor(num('fallbackLimitTokens', 1000)),
    onMaxTokens: bool('onMaxTokens'),
    allowSubagent: bool('allowSubagent'),
    keepRecent: Math.max(1, Math.floor(num('keepRecent', 1))),
    maxCharsPerMessage: Math.max(80, Math.floor(num('maxCharsPerMessage', 80))),
    maxTotalChars: Math.max(400, Math.floor(num('maxTotalChars', 400))),
    autoPrompt: bool('autoPrompt'),
  }
}

/**
 * Collect the readable text of one message's content blocks.
 * @param {unknown} content - message content blocks.
 * @returns {string} trimmed text, or an empty string.
 */
function textOf(content) {
  if (!Array.isArray(content)) return ''
  const parts = []
  for (const block of content) {
    if (block !== null && typeof block === 'object' && block.type === 'text' && typeof block.text === 'string') {
      parts.push(block.text)
    }
  }
  return parts.join('\n').trim()
}

/**
 * Read the model context window of the latest request of one Session.
 * @param {any} session - live Session.
 * @returns {number} context window in tokens, or `0` when unknown.
 */
function contextWindowOf(session) {
  try {
    const context = typeof session.requestContext === 'function' ? session.requestContext() : undefined
    const window = context === null || context === undefined ? NaN : Number(context.contextWindow)
    return Number.isFinite(window) && window > 0 ? window : 0
  } catch {
    return 0
  }
}

/**
 * Measure the current request pressure of one Session.
 * @param {any} meter - `ctx.tokenMeter`.
 * @param {any} session - live Session.
 * @returns {number} total tokens, or `0` when unknown.
 */
function measureTokens(meter, session) {
  try {
    const measured = meter.measure(session)
    const total = measured === null || measured === undefined ? NaN : Number(measured.totalTokens)
    if (Number.isFinite(total) && total > 0) return Math.round(total)
  } catch {
    // fall through to the durable usage fallback
  }
  try {
    const events = session.snapshotEvents()
    for (let index = events.length - 1; index >= 0; index -= 1) {
      const event = events[index]
      if (event.type !== 'assistant/message') continue
      const usage = event.data?.usage
      if (usage === null || typeof usage !== 'object') continue
      const total = Number(usage.totalTokens)
      if (Number.isFinite(total) && total > 0) return Math.round(total)
      const input = Number(usage.inputTokens)
      const output = Number(usage.outputTokens)
      const sum = (Number.isFinite(input) ? input : 0) + (Number.isFinite(output) ? output : 0)
      if (sum > 0) return Math.round(sum)
    }
  } catch {
    // measurement is best effort
  }
  return 0
}

/**
 * Build the digest message handed to the successor Session.
 * @param {any} session - finished Session.
 * @param {{ tokens: number, limit: number, hitMaxTokens: boolean }} info - trigger facts.
 * @param {typeof DEFAULT_OPTIONS} options - resolved options.
 * @returns {string} handoff message text.
 */
function buildHandoff(session, info, options) {
  const lines = []
  lines.push('【自动续接】上一个会话的 token 预算已用尽，本会话自动开启并继承其内容。')
  lines.push('')
  lines.push(`- 上一个会话：${String(session.id)}`)
  if (info.hitMaxTokens) lines.push('- 触发原因：上一条回复达到输出上限而被截断')
  if (info.limit > 0) lines.push(`- 触发阈值：约 ${info.limit} tokens`)
  if (info.tokens > 0) lines.push(`- 实际用量：约 ${info.tokens} tokens`)
  lines.push('')
  lines.push('—— 上一会话的近期对话 ——')

  const transcript = []
  let events = []
  try {
    events = session.snapshotEvents()
  } catch {
    events = []
  }
  for (const event of events) {
    if (event.type === 'user/message') {
      const text = textOf(event.data?.content)
      if (text.length > 0) transcript.push({ role: '用户', text })
    } else if (event.type === 'assistant/message') {
      const text = textOf(event.data?.message?.content)
      if (text.length > 0) transcript.push({ role: '助手', text })
    }
  }

  const recent = transcript.slice(-options.keepRecent)
  for (const entry of recent) {
    const text = entry.text.length > options.maxCharsPerMessage
      ? `${entry.text.slice(0, options.maxCharsPerMessage)}…`
      : entry.text
    lines.push('')
    lines.push(`${entry.role}：${text}`)
  }

  lines.push('')
  lines.push('—— 交接说明 ——')
  lines.push('把以上内容当作已经发生的对话上下文，直接接着做，不要复述摘要。')

  let text = lines.join('\n')
  if (text.length > options.maxTotalChars) {
    const head = lines.slice(0, 7).join('\n')
    const tail = '……\n\n—— 交接说明 ——\n把以上内容当作已经发生的对话上下文，直接接着做，不要复述摘要。'
    const room = Math.max(0, options.maxTotalChars - head.length - tail.length - 8)
    text = `${head}\n\n${transcript.slice(-options.keepRecent).map((entry) => entry.text).join('\n').slice(-room)}${tail}`
  }
  return text
}

/**
 * @param {import('cordis').Context} ctx - owning plugin context.
 * @param {Record<string, unknown>} [config] - Loader row config.
 */
export function apply(ctx, config) {
  const options = normalizeOptions(config)
  /** Sessions with a rollover in flight. */
  const rollingOver = new Set()
  /** Sessions that already rolled over in this process. */
  const rolledOver = new Set()

  const log = (level, message) => {
    const logger = ctx.logger
    if (logger !== undefined && typeof logger[level] === 'function') logger[level](`[token-rollover] ${message}`)
  }

  /**
   * Resolve the workspace that holds a Session, so the successor joins the same group.
   * @param {string} sessionId - source Session id.
   * @returns {any} matching Workspace or `undefined`.
   */
  const workspaceOf = (sessionId) => {
    const registry = ctx.get('workspaceRegistry')
    if (registry === undefined || typeof registry.list !== 'function') return undefined
    try {
      const workspaces = registry.list()
      if (!Array.isArray(workspaces)) return undefined
      return workspaces.find((workspace) => Array.isArray(workspace?.sessionIds) && workspace.sessionIds.includes(sessionId))
    } catch {
      return undefined
    }
  }

  /**
   * Open the successor Session and hand the previous content to it.
   * @param {any} session - finished Session.
   * @param {{ tokens: number, limit: number, hitMaxTokens: boolean }} info - trigger facts.
   */
  const rollover = async (session, info) => {
    const controller = ctx.sessionController

    if (options.mode === 'fork') {
      const forked = await controller.fork({ sessionId: session.id })
      log('info', `session ${String(session.id)} forked into ${String(forked?.sessionId)} (${info.tokens}/${info.limit} tokens)`)
      return
    }

    const request = {}
    const workspace = workspaceOf(session.id)
    if (workspace !== undefined && workspace.id !== undefined) request.workspaceId = workspace.id
    else if (typeof session.header?.cwd === 'string') request.cwd = session.header.cwd
    if (typeof session.header?.agentPreset === 'string') request.agentPreset = session.header.agentPreset

    const created = await controller.create(request)
    const successor = created?.sessionId
    log('info', `session ${String(session.id)} rolled over into ${String(successor)} (${info.tokens}/${info.limit} tokens)`)

    if (!options.autoPrompt) return
    await controller.prompt({
      requestId: `token-rollover-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`,
      sessionId: successor,
      mode: 'queue',
      content: [{ type: 'text', text: buildHandoff(session, info, options) }],
    })
  }

  /**
   * Inspect one committed Session event and roll over when the budget is spent.
   * @param {any} session - live Session.
   * @param {any} event - committed Session event.
   */
  const onSessionEvent = (session, event) => {
    try {
      if (!options.enabled) return
      if (event?.type !== 'turn/end') return
      const reason = event.data?.reason
      const kind = reason !== null && typeof reason === 'object' ? reason.kind : undefined
      if (IGNORED_TURN_END.has(kind)) return

      const header = session.header
      if (header === undefined || header === null) return
      if (header.origin === 'subagent' && !options.allowSubagent) return
      if (rolledOver.has(session.id) || rollingOver.has(session.id)) return

      const tokens = measureTokens(ctx.tokenMeter, session)
      const window = contextWindowOf(session)
      const limit = options.maxTokens > 0
        ? options.maxTokens
        : window > 0
          ? Math.round(window * options.ratio)
          : options.fallbackLimitTokens
      const hitMaxTokens = options.onMaxTokens && kind === 'max-tokens'
      const overLimit = limit > 0 && tokens >= limit
      if (!hitMaxTokens && !overLimit) return

      rollingOver.add(session.id)
      void rollover(session, { tokens, limit, hitMaxTokens })
        .then(() => {
          rolledOver.add(session.id)
        })
        .catch((error) => {
          log('warn', `rollover failed for ${String(session.id)}: ${String(error)}`)
        })
        .finally(() => {
          rollingOver.delete(session.id)
        })
    } catch (error) {
      log('warn', `turn-end inspection failed: ${String(error)}`)
    }
  }

  ctx.effect(() => ctx.on('session/event', onSessionEvent), 'session-token-rollover.listen')
  ctx.effect(() => () => {
    rollingOver.clear()
    rolledOver.clear()
  }, 'session-token-rollover.state')
}