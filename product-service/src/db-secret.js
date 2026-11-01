// Database credentials.
//
// In AWS the credentials live in AWS Secrets Manager (the secret RDS manages for the database) and the app reads
// them itself at runtime with the task role. Nothing sensitive is in the task definition, the image or the code.
// DB_SECRET_ARN names the secret. When it is not set (local development, the unit tests) the credentials come from
// DB_USER and DB_PASSWORD instead.
//
// The secret is rotated by RDS (every 7 days here), which changes the database password. The value is cached in
// memory, and db.js calls refresh() when a login fails, so a rotation costs one reconnect instead of an outage.
const logger = require('./logger');

// Never fetch more often than this, so a persistent failure does not turn into a flood of API calls
const MIN_REFRESH_INTERVAL_MS = 10000;

function create({ secretArn = process.env.DB_SECRET_ARN, env = process.env, client, now = Date.now } = {}) {
  let cached = null;
  let inflight = null;
  let fetchedAt = 0;
  let version = 0; // counts how many times the secret has been loaded, so a caller can tell whether it changed

  function getClient() {
    if (!client) {
      // Loaded only when a secret is used, so local development and the tests never need AWS
      const { SecretsManagerClient } = require('@aws-sdk/client-secrets-manager');
      client = new SecretsManagerClient({ region: env.AWS_REGION || env.AWS_DEFAULT_REGION });
    }
    return client;
  }

  async function fetchSecret() {
    const { GetSecretValueCommand } = require('@aws-sdk/client-secrets-manager');
    const res = await getClient().send(new GetSecretValueCommand({ SecretId: secretArn }));
    let parsed;
    try {
      parsed = JSON.parse(res.SecretString);
    } catch {
      // The message must not include the secret text
      throw new Error('The database secret is not valid JSON');
    }
    if (!parsed || typeof parsed.username !== 'string' || !parsed.username ||
        typeof parsed.password !== 'string' || !parsed.password) {
      throw new Error('The database secret has no username and password');
    }
    return { username: parsed.username, password: parsed.password };
  }

  function load() {
    if (!inflight) {
      inflight = fetchSecret()
        .then((value) => {
          cached = value;
          fetchedAt = now();
          version += 1;
          logger.info('Database credentials loaded from Secrets Manager');
          return value;
        })
        .finally(() => { inflight = null; });
    }
    return inflight;
  }

  return {
    // True when the credentials come from Secrets Manager, so a failed login can be retried with a fresh copy
    canRefresh: () => Boolean(secretArn),

    // Changes every time the secret is loaded. A query that failed to log in compares it with the value from before it
    // started: if it changed, another request has already fetched the new password, so a retry is worthwhile.
    version: () => version,

    async get() {
      if (!secretArn) return { username: env.DB_USER, password: env.DB_PASSWORD };
      return cached || load();
    },

    // Fetch the secret again, unless it was fetched in the last few seconds. Returns true if the cached value is
    // from a fetch made after the call that asked (so a retry is worth making).
    async refresh() {
      if (!secretArn) return false;
      if (inflight) { await inflight; return true; }
      if (cached && now() - fetchedAt < MIN_REFRESH_INTERVAL_MS) return false;
      await load();
      return true;
    },
  };
}

module.exports = { create, ...create() };
