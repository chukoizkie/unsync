const WebSocket = require('ws');
const admin = require('firebase-admin');
const serviceAccount = require('./serviceAccount.json');

admin.initializeApp({ credential: admin.credential.cert(serviceAccount) });

const PORT = Number(process.env.SIGNALING_PORT || 4000);
// Ringing/offline call offers live at most 60 seconds, even if the env asks for more
const CALL_TTL_MS = Math.min(Number(process.env.CALL_TTL_MS || 60_000), 60_000);
const MAX_BUFFERED_ICE = Number(process.env.MAX_BUFFERED_ICE || 50);

const wss = new WebSocket.Server({ port: PORT });

const peers = new Map();      // peerId -> WebSocket
const socketIds = new Map();  // WebSocket -> peerId
const fcmTokens = new Map();  // peerId -> token
const activeKnocks = new Set();

// callId -> {
//   callId, caller, callee, offer, callerName, createdAt, expiresAt,
//   status: 'ringing', callerIce: [], calleeIce: []
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

function requiredString(value) {
  if (value === undefined || value === null) return null;
  const text = String(value);
  return text.length > 0 ? text : null;
}

function rejectCallEvent(ws, type, reason, callId = null) {
  console.log(`call event rejected: type=${type} callId=${callId || 'missing'} reason=${reason}`);
  sendJson(ws, { type: 'error', message: `Invalid ${type}: ${reason}` });
}

function ignoreStaleCallEvent(type, reason, callId = null) {
  console.log(`stale call event ignored: type=${type} callId=${callId || 'missing'} reason=${reason}`);
}

function isCallParticipant(call, fromId, toId) {
  return (
    (call.caller === fromId && call.callee === toId) ||
    (call.callee === fromId && call.caller === toId)
  );
}

function expireOldCalls() {
  const now = Date.now();
  for (const [callId, call] of activeCalls) {
    if (call.status === 'ringing' && call.expiresAt <= now) {
      activeCalls.delete(callId);
      console.log(`expired pending ringing call dropped: ${callId}`);
    }
  }
}

setInterval(expireOldCalls, 10_000).unref();

async function sendFCMPing(token, fromId, extraData = {}) {
  try {
    const messageId = await admin.messaging().send({
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
    return { ok: true, messageId };
  } catch (e) {
    return {
      ok: false,
      errorCode: e.code || 'unknown',
      errorMessage: e.message || String(e),
    };
  }
}

async function wakeForCall(calleeId, callerId, callerName, callId, expiresAt) {
  const token = fcmTokens.get(calleeId);
  if (!token) return false;
  const tokenPrefix = token.substring(0, 20);
  const result = await sendFCMPing(token, callerId, {
    type: 'call_offer',
    callerId,
    callerName: callerName || callerId,
    callId,
    expiresAt,
  });
  if (result.ok) {
    console.log(
      `call_offer FCM wake sent calleeId=${calleeId} callId=${callId} tokenPrefix=${tokenPrefix} messageId=${result.messageId}`
    );
    return true;
  }

  console.log(
    `call_offer FCM wake failed calleeId=${calleeId} callId=${callId} tokenPrefix=${tokenPrefix} errorCode=${result.errorCode} errorMessage=${result.errorMessage}`
  );
  if (
    result.errorCode === 'messaging/registration-token-not-registered' ||
    result.errorCode === 'messaging/invalid-registration-token'
  ) {
    fcmTokens.delete(calleeId);
    console.log(`removed invalid FCM token calleeId=${calleeId} callId=${callId} tokenPrefix=${tokenPrefix}`);
  }
  return false;
}

function deliverPendingCalls(peerId) {
  expireOldCalls();

  const ws = peers.get(peerId);
  if (!isOpen(ws)) return;

  const now = Date.now();
  for (const call of activeCalls.values()) {
    if (call.callee !== peerId) continue;
    if (call.status !== 'ringing') {
      activeCalls.delete(call.callId);
      continue;
    }
    if (call.expiresAt <= now) {
      activeCalls.delete(call.callId);
      console.log(`expired pending ringing call dropped: ${call.callId}`);
      continue;
    }

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
      createdAt: call.createdAt,
      expiresAt: call.expiresAt,
    });
    console.log(`replaying valid pending ringing call: ${call.caller} → ${call.callee} callId=${call.callId}`);

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
  const callId = requiredString(msg.callId);
  const toId = requiredString(msg.to);
  if (!callId || !toId || !msg.candidate) return false;

  const call = activeCalls.get(callId);
  if (!call || call.status !== 'ringing') return false;
  if (!isCallParticipant(call, fromId, toId)) return false;

  const direction = fromId === call.caller ? 'callerIce' : 'calleeIce';
  const buffer = call[direction];
  if (buffer.length >= MAX_BUFFERED_ICE) buffer.shift();
  buffer.push(msg.candidate);
  console.log(`ICE buffered: ${fromId} → ${msg.to} callId=${call.callId}`);
  return true;
}

function forwardOrBufferIce(fromId, msg, ws) {
  const type = msg.type || 'ice';
  const toId = requiredString(msg.to);
  if (!toId || !msg.candidate) {
    rejectCallEvent(ws, type, 'missing to or candidate', msg.callId);
    return;
  }

  const callId = requiredString(msg.callId);
  const call = callId ? activeCalls.get(callId) : null;
  const hasCallBetweenPeers = call && isCallParticipant(call, fromId, toId);
  const activePendingCallForPeers = Array.from(activeCalls.values()).some(
    (candidate) => isCallParticipant(candidate, fromId, toId)
  );

  if (type === 'call_ice' && !callId) {
    rejectCallEvent(ws, 'call_ice', 'missing callId');
    return;
  }

  if (callId && call && !hasCallBetweenPeers) {
    ignoreStaleCallEvent(type, 'participant mismatch', callId);
    return;
  }

  if (!callId && activePendingCallForPeers) {
    rejectCallEvent(ws, type, 'missing callId for active call ICE');
    return;
  }

  const target = peers.get(toId);
  if (isOpen(target)) {
    const payload = { ...msg, type: 'ice', from: fromId, to: toId };
    if (callId) payload.callId = callId;
    sendJson(target, payload);
    console.log(`ice forwarded: ${fromId} → ${msg.to}`);
    return;
  }

  if (storeIceIfCallPending(fromId, msg)) return;

  if (callId) {
    ignoreStaleCallEvent(type, 'no active pending call for offline target', callId);
    return;
  }

  sendJson(ws, { type: 'error', message: 'Peer not found or offline' });
}

function forwardCallEvent(fromId, msg, ws) {
  const type = msg.type;
  const callId = requiredString(msg.callId);
  const toId = requiredString(msg.to);
  if (!callId || !toId) {
    rejectCallEvent(ws, type, 'missing callId or to', callId);
    return;
  }

  const call = activeCalls.get(callId);
  if (!call) {
    if (type === 'call_end') {
      const target = peers.get(toId);
      if (isOpen(target)) {
        sendJson(target, { ...msg, from: fromId, to: toId, callId });
        console.log(`call_end forwarded without pending call: ${fromId} -> ${toId} callId=${callId}`);
        return;
      }
    }
    ignoreStaleCallEvent(type, 'no active call', callId);
    return;
  }

  if (!isCallParticipant(call, fromId, toId)) {
    ignoreStaleCallEvent(type, 'participant mismatch', callId);
    return;
  }

  const target = peers.get(toId);

  if (type === 'call_answer') {
    if (call.callee !== fromId || call.caller !== toId || !msg.sdp) {
      rejectCallEvent(ws, type, 'invalid answer sender or missing sdp', callId);
      return;
    }

    if (isOpen(target)) {
      sendJson(target, { ...msg, from: fromId, to: toId, callId });
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
    activeCalls.delete(callId);
    return;
  }

  if (type === 'call_end' || type === 'call_declined') {
    // Deleting the call also drops its buffered caller/callee ICE
    activeCalls.delete(callId);
    if (call.status === 'ringing') {
      console.log(`removed ringing call on ${type === 'call_end' ? 'caller end' : 'decline'}: callId=${callId}`);
    }
    if (isOpen(target)) {
      sendJson(target, { ...msg, from: fromId, to: toId, callId });
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
    sendJson(otherWs, { type: 'call_end', from: peerId, to: otherId, callId });
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

          const old = peers.get(myId);
          if (old && old !== ws) { try { old.terminate(); } catch {} }
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

        case 'ice':
        case 'call_ice': {
          forwardOrBufferIce(myId, msg, ws);
          break;
        }

        case 'call_offer': {
          expireOldCalls();

          const caller = myId;
          const callee = requiredString(msg.to);
          const callId = requiredString(msg.callId);
          if (!callee || !callId || !msg.sdp) {
            rejectCallEvent(ws, 'call_offer', 'missing callId, to, or sdp', callId);
            break;
          }
          if (activeCalls.has(callId)) {
            ignoreStaleCallEvent('call_offer', 'duplicate active callId', callId);
            break;
          }
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
            sendJson(target, {
              ...msg,
              from: caller,
              callId,
              createdAt: call.createdAt,
              expiresAt: call.expiresAt,
            });
            console.log(`call_offer forwarded: ${caller} → ${callee} callId=${callId}`);
          } else {
            const woke = await wakeForCall(callee, caller, callerName, callId, call.expiresAt);
            if (!woke) {
              activeCalls.delete(callId);
              sendJson(ws, { type: 'error', message: 'Peer not found or offline' });
            } else {
              console.log(`stored offline ringing call: ${caller} → ${callee} callId=${callId} expiresAt=${call.expiresAt}`);
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
    if (id) {
      if (peers.get(id) === ws) {
        handleDisconnect(id);
      } else {
        console.log(`Stale socket closed for ${id}, keeping newer registration`);
      }
    }
  });
});
