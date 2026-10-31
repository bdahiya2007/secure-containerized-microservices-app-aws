// Minimal structured logger: one JSON object per line, so CloudWatch Logs can filter and search by field.
// Level is set with LOG_LEVEL (debug, info, warn, error; default info). Errors go to stderr, the rest to stdout.
const LEVELS = { debug: 10, info: 20, warn: 30, error: 40 };
const threshold = LEVELS[(process.env.LOG_LEVEL || 'info').toLowerCase()] || LEVELS.info;

let sink = (level, line) => {
  (level === 'error' ? process.stderr : process.stdout).write(`${line}\n`);
};

function log(level, msg, fields = {}) {
  if (LEVELS[level] < threshold) return;
  sink(level, JSON.stringify({ time: new Date().toISOString(), level, msg, ...fields }));
}

module.exports = {
  debug: (msg, fields) => log('debug', msg, fields),
  info: (msg, fields) => log('info', msg, fields),
  warn: (msg, fields) => log('warn', msg, fields),
  error: (msg, fields) => log('error', msg, fields),
  // Lets tests capture log lines instead of writing them to the console
  setSink: (fn) => { sink = fn; },
};
