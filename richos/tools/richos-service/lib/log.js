/**
 * RichOS local service — logging.
 *
 * Two rules: (1) never write to stdout when acting as a native-messaging host — stdout is the
 * binary framed channel to Chrome, so every diagnostic goes to stderr; (2) anomalies are LOUD.
 */

const LEVELS = { debug: 10, info: 20, warn: 30, error: 40, alarm: 50 };
const threshold = LEVELS[process.env.RICHOS_LOG_LEVEL] || LEVELS.info;

function emit(level, msg, extra) {
  if (LEVELS[level] < threshold) return;
  const line = `[richos-service ${level}] ${msg}`;
  const suffix = extra ? ` ${JSON.stringify(extra)}` : '';
  process.stderr.write(`${line}${suffix}\n`);
}

export const log = {
  debug: (m, e) => emit('debug', m, e),
  info: (m, e) => emit('info', m, e),
  warn: (m, e) => emit('warn', m, e),
  error: (m, e) => emit('error', m, e),
  /** A never-silent reliability alarm — a captured call that may not have landed a transcript. */
  alarm: (m, e) => emit('alarm', `⚠ ANOMALY: ${m}`, e),
};
