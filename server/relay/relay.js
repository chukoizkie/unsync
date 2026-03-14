const WebSocket = require('ws');
const PORT = 5000;
const queue = new Map();
const peers = new Map();
const bundles = new Map();
const wss = new WebSocket.Server({ port: PORT });
wss.on('connection', (ws) => {
  let myId = null;
  ws.on('message', (data) => {
    try {
      const msg = JSON.parse(data);
      switch (msg.type) {
        case 'register':
          myId = msg.id;
          peers.set(myId, ws);
          console.log('Relay: peer registered: ' + myId);
          ws.send(JSON.stringify({ type: 'registered', id: myId }));
          if (queue.has(myId) && queue.get(myId).length > 0) {
            const blobs = queue.get(myId);
            console.log('Relay: flushing ' + blobs.length + ' msgs to ' + myId);
            blobs.forEach(blob => ws.send(JSON.stringify(blob)));
            queue.delete(myId);
          }
          break;
        case 'upload_bundle':
          bundles.set(msg.id, msg.bundle);
          console.log('Relay: bundle stored for ' + msg.id);
          ws.send(JSON.stringify({ type: 'bundle_uploaded', id: msg.id }));
          break;
        case 'get_bundle':
          const bundle = bundles.get(msg.id);
          if (bundle) {
            ws.send(JSON.stringify({ type: 'bundle', id: msg.id, bundle }));
            console.log('Relay: bundle served for ' + msg.id);
          } else {
            ws.send(JSON.stringify({ type: 'bundle_not_found', id: msg.id }));
          }
          break;
        case 'store':
          const { to, from, payload } = msg;
          if (!queue.has(to)) queue.set(to, []);
          queue.get(to).push({ type: 'queued', from, payload });
          console.log('Relay: stored blob for ' + to + ' from ' + from);
          ws.send(JSON.stringify({ type: 'stored', to }));
          if (peers.has(to)) {
            peers.get(to).send(JSON.stringify({ type: 'queued', from, payload }));
            queue.delete(to);
            console.log('Relay: delivered immediately to ' + to);
          }
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
