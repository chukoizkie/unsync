const WebSocket = require('ws');
const wss = new WebSocket.Server({ port: 4000 });
const admin = require('firebase-admin');
const serviceAccount = require('./serviceAccount.json');
admin.initializeApp({ credential: admin.credential.cert(serviceAccount) });

const peers = new Map();
const fcmTokens = new Map();

async function sendFCMPing(token, fromId, extraData = {}) {
  try {
    await admin.messaging().send({
      token: token,
      data: { type: 'ping', from: fromId, ...extraData },
      android: { priority: 'high' }
    });
    console.log('FCM ping sent to ' + token.substring(0, 20));
  } catch (e) {
    console.log('FCM ping failed: ' + e.message);
  }
}
const activeKnocks = new Set();
console.log('Unsync signaling server running on port 4000');
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
          console.log(`Peer registered: ${myId} fcm: ${msg.fcmToken ? 'yes' : 'no'}`);
          ws.send(JSON.stringify({ type: 'registered', id: myId }));
          break;
        case 'offer':
        case 'answer':
        case 'ice':
        case 'call_answer':
        case 'call_end':
        case 'call_declined': {
          const target = peers.get(msg.to);
          if (target && target.readyState === WebSocket.OPEN) {
            target.send(JSON.stringify({ ...msg, from: myId }));
            console.log(`${msg.type} forwarded: ${myId} → ${msg.to}`);
          } else {
            ws.send(JSON.stringify({ type: 'error', message: 'Peer not found or offline' }));
          }
          break;
        }
        case 'call_offer': {
          const target = peers.get(msg.to);
          if (target && target.readyState === WebSocket.OPEN) {
            target.send(JSON.stringify({ ...msg, from: myId }));
            console.log(`call_offer forwarded: ${myId} → ${msg.to}`);
          } else {
            // Target offline/killed — wake via FCM
            const token = fcmTokens.get(msg.to);
            if (token) {
              const callerName = msg.callerName || myId;
              await sendFCMPing(token, myId, {
                type: 'call_offer',
                callerName: callerName,
                sdp: JSON.stringify(msg.sdp)
              });
              console.log(`call_offer FCM wake sent to ${msg.to}`);
            } else {
              ws.send(JSON.stringify({ type: 'error', message: 'Peer not found or offline' }));
            }
          }
          break;
        }
        case 'knock':
          const knockKey = [myId, msg.to].sort().join('-');
          if (activeKnocks.has(knockKey)) {
            console.log(`Knock deduplicated: ${myId} → ${msg.to}`);
            break;
          }
          activeKnocks.add(knockKey);
          setTimeout(() => activeKnocks.delete(knockKey), 30000);
          const peer = peers.get(msg.to);
          if (peer && peer.readyState === WebSocket.OPEN) {
            peer.send(JSON.stringify({ type: 'knock', from: myId }));
            console.log(`Knock: ${myId} → ${msg.to}`);
          } else {
            ws.send(JSON.stringify({ type: 'peer_offline', id: msg.to }));
            const offlineToken = fcmTokens.get(msg.to);
            if (offlineToken) sendFCMPing(offlineToken, myId);
          }
          break;
        case 'ping':
          // keepalive, ignore
          break;
        default:
          console.log('Unknown message type:', msg.type);
      }
    } catch (e) {
      console.error('Error:', e.message);
    }
  });
  ws.on('close', () => {
    if (myId) {
      peers.delete(myId);
    fcmTokens.delete(myId);
      console.log(`Peer disconnected: ${myId}`);
    }
  });
});
// already handled inline
// already handled inline
