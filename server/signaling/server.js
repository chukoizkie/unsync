const WebSocket = require('ws');
const admin = require('firebase-admin');
const serviceAccount = require('./serviceAccount.json');

admin.initializeApp({ credential: admin.credential.cert(serviceAccount) });

const PORT = Number(process.env.SIGNALING_PORT || 4000);
const CALL_TTL_MS = Number(process.env.CALL_TTL_MS || 60_000);
const MAX_BUFFERED_ICE = Number(process.env.MAX_BUFFERED_ICE || 50);

const wss = new WebSocket.Server({ port: PORT });

const peers = new Map();      // peerId -> WebSocket
const socketIds = new Map();  // WebSocket -> peerId
const fcmTokens = new Map();  // peerId -> token
const activeKnocks = new Set();

// callId -> {
//   callId, caller, callee, offer, callerName, createdAt, expiresAt,
//   status: 'ringing' | 'answered', callerIce: [], calleeIce: []
// }
const activeCalls = new Map();

function isOpen(ws) {
  return ws && ws.readyState === WebSocket.OPEN;
}

function sendJson(ws, payload) {
  if (!isOpen(ws)) return false;
  ws.send(JSON.stringify(payload));
  return true;
}

function getCallKey(msg, fromId) {
  if (msg.callId) return String(msg.callId);
  if (!fromId || !msg.to) return null;
  return [fromId, msg.to].sort().join(':');
}

function getCallForPeers(a, b) {
  for (const call of activeCalls.values()) {
    if (
      (call.caller === a && call.callee === b) ||
      (call.caller === b && call.callee === a)
    ) {
      return call;
    }
  }
  return null;
}

function deleteCall(callId) {
  if (!callId) return;
  activeCalls.delete(callId);
}

function expireOldCalls() {
  const now = Date.now();
  for (const [callId, call] of activeCalls) {
    if (call.status === 'ringing' && call.expiresAt <= now) {
      activeCalls.delete(callId);
      console.log(`pending call expired: ${callId}`);
    }
  }
}

setInterval(expireOldCalls, 10_000).unref();

async function sendFCMPing(token, fromId, extraData = {}) {
  try {
    await admin.messaging().send({
      token,
      data: {
        type: 'ping',
        callerId: String(fromId),
        ...Object.fromEntries(
          Object.entries(extraData).map(([k, v]) => [k, String(v)])
        ),
      },
      android: { priority: 'high' },
    });
    console.log('FCM ping sent to ' + token.substring(0, 20));
  } catch (e) {
    console.log('FCM ping failed: ' + e.message);
  }
}

async function wakeForCall(calleeId, callerId, callerName, callId) {
  const token = fcmTokens.get(calleeId);
  if (!token) return false;
  await sendFCMPing(token, callerId, {
    type: 'call_offer',
    callerName: callerName || callerId,
    callId,
  });
  console.log(`call_offer FCM wake sent to ${calleeId} callId=${callId}`);
  return true;
}

function deliverPendingCalls(peerId) {
  expireOldCalls();

  const ws = peers.get(peerId);
  if (!isOpen(ws)) return;

  for (const call of activeCalls.values()) {
    if (call.callee !== peerId) continue;

    const callerWs = peers.get(call.caller);
    if (!isOpen(callerWs)) {
      activeCalls.delete(call.callId);
      console.log(`pending call dropped because caller is offline: ${call.callId}`);
      continue;
    }

    sendJson(ws, {
      type: 'call_offer',
      from: call.caller,
      to: call.callee,
      sdp: call.offer,
      callerName: call.callerName,
      callId: call.callId,
    });
    console.log(`pending call_offer delivered: ${call.caller} → ${call.callee} callId=${call.callId}`);

    for (const candidate of call.callerIce.splice(0)) {
      sendJson(ws, {
        type: 'ice',
        from: call.caller,
        to: call.callee,
        candidate,
        callId: call.callId,
      });
    }
  }
}

function storeIceIfCallPending(fromId, msg) {
  const call = msg.callId ? activeCalls.get(String(msg.callId)) : getCallForPeers(fromId, msg.to);
  if (!call) return false;

  const direction = fromId === call.caller ? 'callerIce' : 'calleeIce';
  const buffer = call[direction];
  if (buffer.length >= MAX_BUFFERED_ICE) buffer.shift();
  buffer.push(msg.candidate);
  console.log(`ICE buffered: ${fromId} → ${msg.to} callId=${call.callId}`);
  return true;
}

function forwardOrBufferIce(fromId, msg, ws) {
  const target = peers.get(msg.to);
  if (isOpen(target)) {
    sendJson(target, { ...msg, from: fromId });
    console.log(`ice forwarded: ${fromId} → ${msg.to}`);
    return;
  }

  if (storeIceIfCallPending(fromId, msg)) return;

  sendJson(ws, { type: 'error', message: 'Peer not found or offline' });
}

function forwardCallEvent(fromId, msg, ws) {
  const callId = msg.callId ? String(msg.callId) : null;
  const call = callId ? activeCalls.get(callId) : getCallForPeers(fromId, msg.to);
  const target = peers.get(msg.to);

  if (msg.type === 'call_answer') {
    if (call) {
      call.status = 'answered';
      call.answer = msg.sdp;
    }

    if (isOpen(target)) {
      sendJson(target, { ...msg, from: fromId });
      console.log(`call_answer forwarded: ${fromId} → ${msg.to} callId=${callId}`);

      if (call) {
        for (const candidate of call.calleeIce.splice(0)) {
          sendJson(target, {
            type: 'ice',
            from: call.callee,
            to: call.caller,
            candidate,
            callId: call.callId,
          });
        }
      }
    } else {
      console.log(`call_answer target offline, kept call state: ${fromId} → ${msg.to} callId=${callId}`);
    }
    return;
  }

  if (msg.type === 'call_end' || msg.type === 'call_declined') {
    if (call) activeCalls.delete(call.callId);
    if (isOpen(target)) {
      sendJson(target, { ...msg, from: fromId });
      console.log(`${msg.type} forwarded: ${fromId} → ${msg.to} callId=${callId}`);
    } else {
      console.log(`${msg.type} target offline, call cleared: ${fromId} → ${msg.to} callId=${callId}`);
    }
    return;
  }
}

function handleDisconnect(peerId) {
  peers.delete(peerId);
  console.log(`Peer disconnected: ${peerId}`);

  for (const [callId, call] of Array.from(activeCalls.entries())) {
    if (call.caller !== peerId && call.callee !== peerId) continue;

    if (call.status === 'answered') {
      // WebRTC is self-sufficient once ICE connects — don't kill the call
      // on a transient signaling reconnect
      console.log(`peer disconnected during answered call, keeping call state: ${peerId} callId=${callId}`);
      continue;
    }

    // Only end ringing/pending calls on disconnect
    const otherId = call.caller === peerId ? call.callee : call.caller;
    const otherWs = peers.get(otherId);
    sendJson(otherWs, { type: 'call_end', from: peerId, callId });
    activeCalls.delete(callId);
    console.log(`call_end sent on disconnect (ringing): ${peerId} → ${otherId} callId=${callId}`);
  }
}

console.log(`Unsync signaling server running on port ${PORT}`);

wss.on('connection', (ws) => {
  let myId = null;

  ws.on('message', async (data) => {
    try {
      const msg = JSON.parse(data);

      switch (msg.type) {
        case 'register': {
          myId = String(msg.id);

          const oldWs = peers.get(myId);
          if (oldWs && oldWs !== ws) {
            try { oldWs.close(); } catch (_) {}
          }

          peers.set(myId, ws);
          socketIds.set(ws, myId);
          if (msg.fcmToken) fcmTokens.set(myId, String(msg.fcmToken));

          console.log(`Peer registered: ${myId} fcm: ${msg.fcmToken ? 'yes' : 'no'}`);
          sendJson(ws, { type: 'registered', id: myId });
          deliverPendingCalls(myId);
          break;
        }

        case 'offer':
        case 'answer': {
          const target = peers.get(msg.to);
          if (isOpen(target)) {
            sendJson(target, { ...msg, from: myId });
            console.log(`${msg.type} forwarded: ${myId} → ${msg.to}`);
          } else {
            sendJson(ws, { type: 'error', message: 'Peer not found or offline' });
          }
          break;
        }

        case 'ice': {
          forwardOrBufferIce(myId, msg, ws);
          break;
        }

        case 'call_offer': {
          expireOldCalls();

          const caller = myId;
          const callee = String(msg.to);
          const callId = getCallKey(msg, caller) || `${caller}_${callee}_${Date.now()}`;
          const callerName = msg.callerName || caller;

          const call = {
            callId,
            caller,
            callee,
            offer: msg.sdp,
            callerName,
            createdAt: Date.now(),
            expiresAt: Date.now() + CALL_TTL_MS,
            status: 'ringing',
            callerIce: [],
            calleeIce: [],
          };
          activeCalls.set(callId, call);

          const target = peers.get(callee);
          if (isOpen(target)) {
            sendJson(target, { ...msg, from: caller, callId });
            console.log(`call_offer forwarded: ${caller} → ${callee} callId=${callId}`);
          } else {
            const woke = await wakeForCall(callee, caller, callerName, callId);
            if (!woke) {
              activeCalls.delete(callId);
              sendJson(ws, { type: 'error', message: 'Peer not found or offline' });
            } else {
              console.log(`pending call stored: ${caller} → ${callee} callId=${callId}`);
            }
          }
          break;
        }

        case 'call_answer':
        case 'call_end':
        case 'call_declined': {
          forwardCallEvent(myId, msg, ws);
          break;
        }

        case 'knock': {
          const knockKey = [myId, msg.to].sort().join('-');
          if (activeKnocks.has(knockKey)) {
            console.log(`Knock deduplicated: ${myId} → ${msg.to}`);
            break;
          }
          activeKnocks.add(knockKey);
          setTimeout(() => activeKnocks.delete(knockKey), 30_000).unref();

          const peer = peers.get(msg.to);
          if (isOpen(peer)) {
            sendJson(peer, { type: 'knock', from: myId });
            console.log(`Knock: ${myId} → ${msg.to}`);
          } else {
            sendJson(ws, { type: 'peer_offline', id: msg.to });
            const offlineToken = fcmTokens.get(msg.to);
            if (offlineToken) sendFCMPing(offlineToken, myId);
          }
          break;
        }

        case 'ping':
          break;

        default:
          console.log('Unknown message type:', msg.type);
      }
    } catch (e) {
      console.error('Error:', e.message);
    }
  });

  ws.on('close', () => {
    const id = myId || socketIds.get(ws);
    socketIds.delete(ws);
    if (id && peers.get(id) === ws) handleDisconnect(id);
  });
});
