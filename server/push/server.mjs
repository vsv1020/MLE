#!/usr/bin/env node
// 麻薯背单词 (com.vocabloop.app) push notification server.
// Node.js 20+, no npm dependencies. Listens on 127.0.0.1 only; nginx proxies to it.
// See README.md for deployment.
import http from 'node:http';
import { loadConfig } from './lib/config.mjs';
import { TokenStore, HistoryStore } from './lib/storage.mjs';
import { ProviderToken } from './lib/jwt.mjs';
import { Http2Transport } from './lib/apns.mjs';
import { createApp } from './lib/app.mjs';

const log = (msg) => console.log(`${new Date().toISOString()} ${msg}`);

const [major] = process.versions.node.split('.').map(Number);
if (major < 20) {
  console.error(`Node.js 20 or newer is required (this is ${process.version}).`);
  process.exit(1);
}

const { config, errors, warnings } = loadConfig();
for (const w of warnings) log(`warning: ${w}`);
if (errors.length) {
  for (const e of errors) console.error(`config error: ${e}`);
  console.error('Refusing to start. Fix /etc/mashu-push.env and run: systemctl restart mashu-push');
  process.exit(1);
}

const store = await new TokenStore(config.dataDir).load();
const history = await new HistoryStore(config.dataDir).load();
const transport = new Http2Transport({ log });
const providerToken = config.apns ? new ProviderToken(config.apns) : null;
if (providerToken) providerToken.get(); // fail fast if the key cannot sign

const handler = createApp({
  adminUser: config.adminUser,
  adminPassword: config.adminPassword,
  store,
  history,
  transport,
  providerToken,
  log,
});

const server = http.createServer(handler);
server.requestTimeout = 120_000;  // a send to many devices can take a while
server.headersTimeout = 10_000;
server.keepAliveTimeout = 5_000;
server.listen(config.port, '127.0.0.1', () => {
  const c = store.counts();
  log(`mashu-push listening on http://127.0.0.1:${config.port} (data ${config.dataDir}; tokens production=${c.production} sandbox=${c.sandbox}; apns ${providerToken ? 'configured' : 'NOT configured'})`);
});

function shutdown(sig) {
  log(`${sig} received, shutting down`);
  server.close(() => { transport.close(); process.exit(0); });
  server.closeIdleConnections?.();
  setTimeout(() => process.exit(0), 10_000).unref();
}
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
