# EQGate — Emotional Intelligence Gateway

A fully client-side emotional intelligence verification system. The LLM runs **in the user's browser** via WebLLM (Qwen3-1.7B). Scores are submitted privately to the server over HMAC-signed WebSocket.

## Architecture

```
┌─────────────────────────────────────────────────┐
│  CLIENT (Browser)                                │
│                                                  │
│  ┌──────────────┐   ┌────────────────────────┐  │
│  │  WebLLM       │   │  EQGate Game Logic   │  │
│  │  Qwen3-1.7B   │◄─►│  Chat, Timer, Scoring  │  │
│  │  (WebGPU)     │   │  Injection Detection   │  │
│  └──────────────┘   └──────────┬─────────────┘  │
│                                 │                 │
│                    HMAC-SHA256 signed score       │
│                                 │                 │
└─────────────────────────────────┼─────────────────┘
                                  │ WebSocket
┌─────────────────────────────────┼─────────────────┐
│  SERVER (Node.js)               ▼                 │
│                                                    │
│  ┌──────────────┐   ┌──────────────────────────┐ │
│  │  Express      │   │  WebSocket Server         │ │
│  │  /api/session │   │  /ws                      │ │
│  │  /api/scores  │   │  Validate HMAC + bounds   │ │
│  │  /api/health  │   │  Store scores privately   │ │
│  └──────────────┘   └──────────────────────────┘ │
│                                                    │
│  Optional: ngrok http 3000 → public URL           │
└────────────────────────────────────────────────────┘
```

## Quick Start

```bash
# Install dependencies
npm install

# Start the server
npm start
# → http://localhost:3000

# For remote access (e.g. hackathon demo)
ngrok http 3000
# → https://xxxx.ngrok-free.app
```

## How It Works

### Client Side
1. Browser loads the page and downloads Qwen3-1.7B (~1GB, cached after first load)
2. A session is created via `POST /api/session` → returns `{sessionId, secret}`
3. The game picks a random feeling and uses the local LLM to roleplay a character
4. User converses and guesses the feeling
5. Score = speedScore (0-50, time remaining) + kindScore (0-50, conversation quality)
6. Score is HMAC-SHA256 signed with the session secret and sent over WebSocket

### Server Side
1. Creates sessions with unique secrets
2. Receives score over WebSocket
3. Validates: HMAC signature, score bounds, single-submission per session
4. Stores score privately — never exposed to other clients

### Security Model
- **No data leaves the browser** during gameplay (all LLM inference is local)
- **HMAC signing** prevents score tampering in transit
- **Session binding** prevents replay attacks
- **Single-use sessions** prevent score re-submission
- **Injection detection** catches prompt injection attempts client-side AND server-side
- **Bound validation** rejects impossible scores

## Model

Uses **Qwen3-1.7B** (q4f16_1 quantization) via [WebLLM](https://webllm.mlc.ai/).

- First load: ~1GB download (cached in browser for all future visits)
- Requires **WebGPU** support (Chrome 113+, Edge 113+)
- Falls back to Qwen2.5-1.5B-Instruct if Qwen3 isn't in the runtime's prebuilt model list

## API Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/` | GET | Serves the EQGate client |
| `/api/session` | POST | Creates a new session → `{sessionId, secret}` |
| `/api/scores` | GET | View last 50 scores (admin) |
| `/api/health` | GET | Server status |
| `/ws` | WS | Private score submission channel |

## Score Submission Protocol

```javascript
// Client sends:
{
  type: 'score_submit',
  sessionId: '...',
  payload: { score, speedScore, kindScore, level, feeling, correct, timeRemaining, compromised },
  hmac: HMAC_SHA256(sessionSecret, JSON.stringify(payload))
}

// Server responds:
{
  type: 'score_ack',
  status: 'accepted' | 'error',
  record: { ... } | undefined,
  reason: '...' | undefined
}
```

## Platform Integration

### Option A — Iframe (cross-origin safe)
```html
<iframe src="https://your-ngrok-url.ngrok-free.app"
  style="width:420px;height:580px;border:none;border-radius:16px"></iframe>

<script>
window.addEventListener('message', function(e) {
  if (e.data?.type !== 'eqGateResult') return;
  const result = e.data.result;
  console.log('Score:', result.score, 'Level:', result.level);
});
</script>
```

### Option B — Direct DOM Mount (same origin)
```html
<div id="captcha-container" style="width:420px;height:580px"></div>
<script>
  EQGate.mount('#captcha-container', {
    onComplete(result) { if (result.level === 'full') enableFeature(); },
    onCompromised(result) { flagAccount(); }
  });
</script>
```

## Environment

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | `3000` | Server listen port |

## Requirements

- Node.js 18+
- npm
- Browser with WebGPU support (Chrome/Edge 113+)
- ~1GB free disk for model cache (browser-side)
