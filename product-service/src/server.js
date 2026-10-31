const app = require('./app');
const pool = require('./db');
const logger = require('./logger');

const PORT = 3000;

const server = app.listen(PORT, '0.0.0.0', () => {
  logger.info('Product Service listening', { port: PORT });
});

// The ALB keeps idle connections to the tasks open for 60 seconds, but Node closes an idle connection after
// 5 seconds by default. If the ALB reuses a connection at the moment Node closes it, that request fails with a
// 502. Keep Node's timeout longer than the ALB's idle timeout, and headersTimeout above keepAliveTimeout.
server.keepAliveTimeout = 65000;
server.headersTimeout = 66000;

// Graceful shutdown so in-flight requests finish when the container is stopped (SIGTERM).
function shutdown(signal) {
  logger.info('Shutting down', { signal });
  server.close(async () => {
    await pool.end();
    process.exit(0);
  });
  setTimeout(() => process.exit(1), 10000).unref();
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
