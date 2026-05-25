const WebSocket = require('ws');
const path = require('path');
const Database = require('better-sqlite3');
let messaging = null;

try {
  const admin = require('firebase-admin');
  let credential;
  try {
    const serviceAccount = require('./serviceAccount.json');
    credential = admin.credential.cert(serviceAccount);
  } catch (_) {
    credential = admin.credential.applicationDefault();
  }
  admin.initializeApp({ credential });
  messaging = admin.messaging();
  console.log('Relay: FCM enabled');
} catch (e) {
  console.log('Relay: FCM disabled: ' + e.message);
}

const PORT = 5000;
const peers = new Map();
const fcmTokens = new Map();
const wss = new WebSocket.Server({ port: PORT });
const dbPath = process.env.RELAY_DB_PATH || path.join(__dirname, 'relay.sqlite');
const db = new Database(dbPath);

db.pragma('journal_mode = WAL');
db.exec(`
  CREATE TABLE IF NOT EXISTS prekey_bundles (
    peer_id TEXT PRIMARY KEY,
    bundle_json TEXT NOT NULL,
    updated_at INTEGER NOT NULL
  );

  CREATE TABLE IF NOT EXISTS encrypted_queue (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    to_id TEXT NOT NULL,
    from_id TEXT NOT NULL,
    payload TEXT NOT NULL,
    created_at INTEGER NOT NULL
  );

  CREATE INDEX IF NOT EXISTS idx_encrypted_queue_to_id
    ON encrypted_queue (to_id, id);
`);

const statements = {
  upsertBundle: db.prepare(`
    INSERT INTO prekey_bundles (peer_id, bundle_json, updated_at)
    VALUES (?, ?, ?)
    ON CONFLICT(peer_id) DO UPDATE SET
      bundle_json = excluded.bundle_json,
      updated_at = excluded.updated_at
  `),
  getBundle: db.prepare(`
    SELECT bundle_json
    FROM prekey_bundles
    WHERE peer_id = ?
  `),
  insertQueuedBlob: db.prepare(`
    INSERT INTO encrypted_queue (to_id, from_id, payload, created_at)
    VALUES (?, ?, ?, ?)
  `),
  getQueuedBlobs: db.prepare(`
    SELECT from_id, payload
    FROM encrypted_queue
    WHERE to_id = ?
    ORDER BY id ASC
  `),
  deleteQueuedBlobs: db.prepare(`
    DELETE FROM encrypted_queue
    WHERE to_id = ?
  `),
};

async function sendMessageWake(to, fromId) {
  if (!messaging) {
    console.log('Relay: no FCM client configured; cannot wake ' + to);
    return;
  }
  const token = fcmTokens.get(to);
  if (!token) {
    console.log('Relay: no FCM token for ' + to);
    return;
  }
  try {
    await messaging.send({
      token,
      data: {
        click_action: 'FLUTTER_NOTIFICATION_CLICK',
        type: 'message_wake',
        senderId: String(fromId),
        fromId: String(fromId),
      },
      android: { priority: 'high' },
    });
    console.log('Relay: message_wake FCM sent to ' + to);
  } catch (e) {
    console.log('Relay: message_wake FCM failed for ' + to + ': ' + e.message);
  }
}

function sendJson(ws, message) {
  return new Promise((resolve, reject) => {
    ws.send(JSON.stringify(message), (error) => {
      if (error) reject(error);
      else resolve();
    });
  });
}

async function flushQueuedBlobs(peerId, ws) {
  const blobs = statements.getQueuedBlobs.all(peerId);
  if (blobs.length === 0) return;

  console.log('Relay: flushing ' + blobs.length + ' msgs to ' + peerId);
  for (const blob of blobs) {
    await sendJson(ws, {
      type: 'queued',
      from: blob.from_id,
      payload: blob.payload,
    });
  }
  statements.deleteQueuedBlobs.run(peerId);
}

wss.on('connection', (ws) => {
  let myId = null;
  ws.on('message', async (data) => {
    try {
      const msg = JSON.parse(data);
      switch (msg.type) {
        case 'register':
          myId = msg.id;
          peers.set(myId, ws);
          if (msg.fcmToken) fcmTokens.set(myId, msg.fcmToken);
          console.log('Relay: peer registered: ' + myId + ' fcm: ' + (msg.fcmToken ? 'yes' : 'no'));
          ws.send(JSON.stringify({ type: 'registered', id: myId }));
          await flushQueuedBlobs(myId, ws);
          break;
        case 'upload_bundle':
          statements.upsertBundle.run(
            msg.id,
            JSON.stringify(msg.bundle),
            Date.now()
          );
          console.log('Relay: bundle stored for ' + msg.id);
          ws.send(JSON.stringify({ type: 'bundle_uploaded', id: msg.id }));
          break;
        case 'get_bundle':
          const row = statements.getBundle.get(msg.id);
          if (row) {
            ws.send(JSON.stringify({
              type: 'bundle',
              id: msg.id,
              bundle: JSON.parse(row.bundle_json),
            }));
            console.log('Relay: bundle served for ' + msg.id);
          } else {
            ws.send(JSON.stringify({ type: 'bundle_not_found', id: msg.id }));
          }
          break;
        case 'store':
          const { to, from, payload } = msg;
          const target = peers.get(to);
          if (target && target.readyState === WebSocket.OPEN) {
            target.send(JSON.stringify({ type: 'queued', from, payload }));
            console.log('Relay: delivered immediately to ' + to);
          } else {
            statements.insertQueuedBlob.run(to, from, payload, Date.now());
            console.log('Relay: stored blob for ' + to + ' from ' + from);
            await sendMessageWake(to, from);
          }
          ws.send(JSON.stringify({ type: 'stored', to }));
          break;
        case 'ping':
          ws.send(JSON.stringify({ type: 'pong' }));
          break;
      }
    } catch (e) {
      console.error('Relay error:', e.message);
    }
  });
  ws.on('close', () => {
    if (myId) {
      peers.delete(myId);
      console.log('Relay: peer disconnected: ' + myId);
    }
  });
});
console.log('Unsync relay daemon running on port 5000');
