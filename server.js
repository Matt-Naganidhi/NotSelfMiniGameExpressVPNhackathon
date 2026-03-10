// ─────────────────────────────────────────────────────────
//  EQGate Server — serves client + receives private scores
//  Works with ngrok: ngrok http 3000
// ─────────────────────────────────────────────────────────

const express = require('express');
const http = require('http');
const { WebSocketServer } = require('ws');
const crypto = require('crypto');
const path = require('path');

const app = express();
const server = http.createServer(app);
const wss = new WebSocketServer({ server, path: '/ws' });

const PORT = process.env.PORT || 3000;

// ── Ngrok URL detection ───────────────────────────────────
let ngrokUrl = null;

function fetchNgrokUrl() {
  return new Promise((resolve) => {
    http.get('http://127.0.0.1:4040/api/tunnels', (res) => {
      let data = '';
      res.on('data', chunk => data += chunk);
      res.on('end', () => {
        try {
          const tunnels = JSON.parse(data).tunnels || [];
          const https = tunnels.find(t => t.proto === 'https');
          resolve(https ? https.public_url : null);
        } catch { resolve(null); }
      });
    }).on('error', () => resolve(null));
  });
}

async function pollNgrokUrl() {
  const url = await fetchNgrokUrl();
  if (url && url !== ngrokUrl) {
    ngrokUrl = url;
    console.log('');
    console.log('╔══════════════════════════════════════════════╗');
    console.log('║  🌐 ngrok tunnel detected!                   ║');
    console.log(`║  Public URL: ${url.padEnd(32)} ║`);
    console.log('║  Share this URL with participants            ║');
    console.log('╚══════════════════════════════════════════════╝');
    console.log('');
  }
  // Poll every 5 seconds in case ngrok starts after the server
  setTimeout(pollNgrokUrl, 5000);
}

// ── Session store ────────────────────────────────────────
// Maps sessionId → { secret, created, ip, score }
const sessions = new Map();
const scores = []; // permanent score log

// ── Middleware ────────────────────────────────────────────
app.use(express.json());

// Serve static client
app.use(express.static(path.join(__dirname, 'public')));

// ── REST: Create session (called by client on page load) ─
app.post('/api/session', (req, res) => {
  const sessionId = crypto.randomUUID();
  const secret = crypto.randomBytes(32).toString('hex');
  const ip = req.headers['x-forwarded-for'] || req.socket.remoteAddress;

  sessions.set(sessionId, {
    secret,
    created: Date.now(),
    ip,
    score: null,
    submitted: false,
  });

  // Auto-expire sessions after 5 minutes
  setTimeout(() => {
    if (sessions.has(sessionId) && !sessions.get(sessionId).submitted) {
      sessions.delete(sessionId);
    }
  }, 5 * 60 * 1000);

  console.log(`[SESSION] Created ${sessionId.slice(0, 8)}… from ${ip}`);
  res.json({ sessionId, secret });
});

// ── REST: View scores (admin endpoint) ───────────────────
app.get('/api/scores', (req, res) => {
  res.json({
    total: scores.length,
    scores: scores.slice(-50).reverse(),
  });
});

// ── REST: Health check ───────────────────────────────────
app.get('/api/health', (req, res) => {
  res.json({
    status: 'ok',
    activeSessions: sessions.size,
    totalScores: scores.length,
    uptime: process.uptime(),
  });
});

// ── REST: Ngrok URL (for clients to discover public URL) ─
app.get('/api/ngrok', (req, res) => {
  res.json({ url: ngrokUrl });
});

// ── WebSocket: Private score channel ─────────────────────
wss.on('connection', (ws, req) => {
  const ip = req.headers['x-forwarded-for'] || req.socket.remoteAddress;
  console.log(`[WS] Client connected from ${ip}`);

  ws.on('message', (raw) => {
    try {
      const msg = JSON.parse(raw.toString());

      if (msg.type === 'score_submit') {
        const { sessionId, payload, hmac } = msg;
        const session = sessions.get(sessionId);

        if (!session) {
          ws.send(JSON.stringify({
            type: 'score_ack',
            status: 'error',
            reason: 'Invalid or expired session',
          }));
          return;
        }

        if (session.submitted) {
          ws.send(JSON.stringify({
            type: 'score_ack',
            status: 'error',
            reason: 'Score already submitted for this session',
          }));
          return;
        }

        // Verify HMAC
        const expectedHmac = crypto
          .createHmac('sha256', session.secret)
          .update(JSON.stringify(payload))
          .digest('hex');

        if (hmac !== expectedHmac) {
          console.log(`[WS] HMAC mismatch for session ${sessionId.slice(0, 8)}`);
          ws.send(JSON.stringify({
            type: 'score_ack',
            status: 'error',
            reason: 'Signature mismatch — possible tampering',
          }));
          return;
        }

        // Validate score bounds
        const { score, speedScore, kindScore, level, feeling, correct, timeRemaining, compromised } = payload;
        if (
          typeof score !== 'number' || score < 0 || score > 100 ||
          typeof speedScore !== 'number' || speedScore < 0 || speedScore > 50 ||
          typeof kindScore !== 'number' || kindScore < 0 || kindScore > 50 ||
          !['full', 'basic', 'limited', 'locked'].includes(level)
        ) {
          ws.send(JSON.stringify({
            type: 'score_ack',
            status: 'error',
            reason: 'Score values out of bounds',
          }));
          return;
        }

        // Accept score
        session.score = payload;
        session.submitted = true;
        session.submittedAt = Date.now();

        const scoreRecord = {
          sessionId: sessionId.slice(0, 8) + '…',
          ip: session.ip,
          ...payload,
          submittedAt: new Date().toISOString(),
          elapsed: session.submittedAt - session.created,
        };

        scores.push(scoreRecord);

        console.log(`[SCORE] ${scoreRecord.sessionId} → ${score}/100 (${level}) feeling=${feeling} correct=${correct}`);

        ws.send(JSON.stringify({
          type: 'score_ack',
          status: 'accepted',
          record: scoreRecord,
        }));
      }
    } catch (e) {
      console.error('[WS] Parse error:', e.message);
      ws.send(JSON.stringify({ type: 'error', reason: 'Invalid message format' }));
    }
  });

  ws.on('close', () => {
    console.log(`[WS] Client disconnected from ${ip}`);
  });
});

// ── Start ────────────────────────────────────────────────
server.listen(PORT, () => {
  console.log('');
  console.log('╔══════════════════════════════════════════════╗');
  console.log('║         EQGate Server Running                ║');
  console.log('╠══════════════════════════════════════════════╣');
  console.log(`║  Local:  http://localhost:${PORT}              ║`);
  console.log('║                                              ║');
  console.log('║  For remote access run in a new terminal:    ║');
  console.log(`║  $ ngrok http ${PORT}                          ║`);
  console.log('║  (public URL will appear here automatically) ║');
  console.log('║                                              ║');
  console.log('║  Admin scores: /api/scores                   ║');
  console.log('║  Health check: /api/health                   ║');
  console.log('║  Ngrok URL:    /api/ngrok                    ║');
  console.log('╚══════════════════════════════════════════════╝');
  console.log('');

  // Start polling for ngrok (in case it's already running or starts later)
  pollNgrokUrl();
});
