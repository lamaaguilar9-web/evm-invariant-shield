import sys, os
project_root = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
if project_root not in sys.path:
    sys.path.insert(0, project_root)
# -*- coding: utf-8 -*-
"""
EVM Invariant Shield - Telemetry Command Center
Port: 5057
Protects Ethereum Mainnet (Uniswap v3 & Aave v3) with Flashbots Protect Private Relays
"""
import os
import uvicorn
from fastapi import FastAPI
from fastapi.responses import HTMLResponse, JSONResponse
from fastapi.middleware.cors import CORSMiddleware
from backend.mempool_watcher import EVMMempoolWatcher

app = FastAPI(title="EVM Invariant Shield", version="1.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

watcher = EVMMempoolWatcher()

HTML_CONTENT = """<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>EVM Invariant Shield — Ethereum Mainnet Sentinel</title>
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@300;400;600;700;800&family=Plus+Jakarta+Sans:wght@400;600;700;800&display=swap" rel="stylesheet">
    <style>
        :root {
            --bg-base: #060913;
            --bg-card: rgba(13, 20, 36, 0.75);
            --border-glow: rgba(98, 126, 234, 0.35);
            --eth-blue: #627eea;
            --eth-purple: #8a92b2;
            --accent-cyan: #00f0ff;
            --accent-emerald: #10b981;
            --accent-crimson: #ef4444;
            --text-main: #f8fafc;
            --text-dim: #94a3b8;
        }

        * {
            box-sizing: border-box;
            margin: 0;
            padding: 0;
        }

        body {
            background: var(--bg-base);
            color: var(--text-main);
            font-family: 'Plus Jakarta Sans', -apple-system, BlinkMacSystemFont, sans-serif;
            min-height: 100vh;
            padding: 24px;
            background-image: 
                radial-gradient(circle at 10% 20%, rgba(98, 126, 234, 0.12) 0%, transparent 40%),
                radial-gradient(circle at 90% 80%, rgba(0, 240, 255, 0.08) 0%, transparent 40%);
        }

        .container {
            max-width: 1400px;
            margin: 0 auto;
        }

        header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            padding-bottom: 24px;
            border-bottom: 1px solid rgba(255, 255, 255, 0.1);
            margin-bottom: 24px;
        }

        .brand {
            display: flex;
            align-items: center;
            gap: 16px;
        }

        .eth-icon {
            width: 46px;
            height: 46px;
            background: linear-gradient(135deg, #627eea, #3b5998);
            border-radius: 12px;
            display: flex;
            align-items: center;
            justify-content: center;
            box-shadow: 0 0 20px rgba(98, 126, 234, 0.5);
            font-weight: 800;
            font-size: 22px;
        }

        .brand-title h1 {
            font-size: 24px;
            font-weight: 800;
            letter-spacing: -0.5px;
            display: flex;
            align-items: center;
            gap: 10px;
        }

        .badge-live {
            background: rgba(16, 185, 129, 0.15);
            color: var(--accent-emerald);
            border: 1px solid var(--accent-emerald);
            padding: 2px 10px;
            border-radius: 20px;
            font-size: 11px;
            font-family: 'JetBrains Mono', monospace;
            font-weight: 700;
            letter-spacing: 0.5px;
        }

        .brand-title p {
            font-size: 13px;
            color: var(--text-dim);
        }

        .header-meta {
            display: flex;
            gap: 20px;
            font-family: 'JetBrains Mono', monospace;
        }

        .meta-tag {
            background: rgba(255, 255, 255, 0.04);
            border: 1px solid rgba(255, 255, 255, 0.08);
            padding: 8px 14px;
            border-radius: 8px;
            font-size: 12px;
        }

        .meta-tag span {
            color: var(--accent-cyan);
            font-weight: 700;
        }

        .grid-stats {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(260px, 1fr));
            gap: 18px;
            margin-bottom: 24px;
        }

        .card {
            background: var(--bg-card);
            border: 1px solid var(--border-glow);
            border-radius: 14px;
            padding: 20px;
            backdrop-filter: blur(12px);
            transition: transform 0.2s ease, border-color 0.2s ease;
        }

        .card:hover {
            border-color: var(--accent-cyan);
            transform: translateY(-2px);
        }

        .card-label {
            font-size: 12px;
            text-transform: uppercase;
            letter-spacing: 1px;
            color: var(--text-dim);
            margin-bottom: 8px;
            display: flex;
            justify-content: space-between;
        }

        .card-val {
            font-size: 26px;
            font-weight: 800;
            font-family: 'JetBrains Mono', monospace;
        }

        .card-sub {
            font-size: 12px;
            color: var(--accent-emerald);
            margin-top: 6px;
            font-family: 'JetBrains Mono', monospace;
        }

        .pools-grid {
            display: grid;
            grid-template-columns: 1fr 1fr;
            gap: 24px;
            margin-bottom: 24px;
        }

        @media (max-width: 960px) {
            .pools-grid { grid-template-columns: 1fr; }
        }

        .pool-card {
            background: var(--bg-card);
            border: 1px solid var(--border-glow);
            border-radius: 16px;
            padding: 24px;
        }

        .pool-header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 18px;
            padding-bottom: 12px;
            border-bottom: 1px solid rgba(255, 255, 255, 0.08);
        }

        .pool-name {
            font-size: 18px;
            font-weight: 700;
            color: var(--text-main);
        }

        .status-pill {
            padding: 4px 12px;
            border-radius: 20px;
            font-size: 11px;
            font-weight: 700;
            font-family: 'JetBrains Mono', monospace;
        }

        .pill-normal {
            background: rgba(16, 185, 129, 0.15);
            color: var(--accent-emerald);
            border: 1px solid rgba(16, 185, 129, 0.3);
        }

        .pill-paused {
            background: rgba(239, 68, 68, 0.2);
            color: var(--accent-crimson);
            border: 1px solid var(--accent-crimson);
            animation: pulse-red 1.5s infinite;
        }

        @keyframes pulse-red {
            0%, 100% { opacity: 1; }
            50% { opacity: 0.6; }
        }

        .pool-metrics {
            display: grid;
            grid-template-columns: 1fr 1fr;
            gap: 12px;
            font-family: 'JetBrains Mono', monospace;
            font-size: 13px;
            margin-bottom: 18px;
        }

        .metric-box {
            background: rgba(255, 255, 255, 0.03);
            padding: 12px;
            border-radius: 8px;
            border: 1px solid rgba(255, 255, 255, 0.05);
        }

        .metric-box div:first-child {
            color: var(--text-dim);
            font-size: 11px;
            margin-bottom: 4px;
        }

        .metric-box div:last-child {
            font-weight: 700;
            color: var(--accent-cyan);
        }

        .actions-panel {
            background: rgba(255, 255, 255, 0.02);
            border: 1px solid rgba(255, 255, 255, 0.08);
            border-radius: 16px;
            padding: 24px;
            margin-bottom: 24px;
        }

        .panel-title {
            font-size: 16px;
            font-weight: 700;
            margin-bottom: 16px;
            display: flex;
            align-items: center;
            gap: 8px;
        }

        .btn-group {
            display: flex;
            gap: 14px;
            flex-wrap: wrap;
        }

        button {
            padding: 12px 24px;
            border-radius: 10px;
            font-family: 'JetBrains Mono', monospace;
            font-size: 13px;
            font-weight: 700;
            cursor: pointer;
            transition: all 0.2s ease;
            border: none;
            display: flex;
            align-items: center;
            gap: 8px;
        }

        .btn-attack {
            background: linear-gradient(135deg, #ef4444, #b91c1c);
            color: white;
            box-shadow: 0 0 15px rgba(239, 68, 68, 0.4);
        }

        .btn-attack:hover {
            transform: scale(1.03);
            box-shadow: 0 0 25px rgba(239, 68, 68, 0.6);
        }

        .btn-reset {
            background: linear-gradient(135deg, #3b82f6, #1d4ed8);
            color: white;
            box-shadow: 0 0 15px rgba(59, 130, 246, 0.4);
        }

        .btn-reset:hover {
            transform: scale(1.03);
            box-shadow: 0 0 25px rgba(59, 130, 246, 0.6);
        }

        .incidents-log {
            background: var(--bg-card);
            border: 1px solid var(--border-glow);
            border-radius: 16px;
            padding: 24px;
            font-family: 'JetBrains Mono', monospace;
        }

        .log-entry {
            background: rgba(0, 0, 0, 0.3);
            border-left: 3px solid var(--accent-cyan);
            padding: 12px 16px;
            margin-top: 10px;
            border-radius: 0 8px 8px 0;
            font-size: 12px;
        }

        .log-time { color: var(--text-dim); }
        .log-drop { color: var(--accent-crimson); font-weight: 700; }
        .log-tx { color: var(--accent-emerald); }
    </style>
</head>
<body>
    <div class="container">
        <header>
            <div class="brand">
                <div class="eth-icon">Ξ</div>
                <div class="brand-title">
                    <h1>EVM Invariant Shield <span class="badge-live">PORT 5057 • ACTIVE</span></h1>
                    <p>Sub-45ms Non-Custodial Circuit Breaker with Flashbots Protect Private Relays (Ethereum L1)</p>
                </div>
            </div>
            <div class="header-meta">
                <div class="meta-tag">Chain: <span>Ethereum Mainnet (1)</span></div>
                <div class="meta-tag">Relay: <span>Flashbots Protect</span></div>
                <div class="meta-tag">Governance: <span>Gnosis Safe 3/5</span></div>
            </div>
        </header>

        <div class="grid-stats">
            <div class="card">
                <div class="card-label">Ethereum L1 Block <span>PoS</span></div>
                <div class="card-val" id="val-block">#21,980,142</div>
                <div class="card-sub">Slot Time: 12.0s • Target: Top-of-Block</div>
            </div>
            <div class="card">
                <div class="card-label">EIP-1559 Base Fee <span>Dynamic</span></div>
                <div class="card-val" id="val-basefee">18.5 Gwei</div>
                <div class="card-sub" id="val-priority">+6.5 Gwei Overbid Protection</div>
            </div>
            <div class="card">
                <div class="card-label">Invariant Math <span>Precision</span></div>
                <div class="card-val">512-bit</div>
                <div class="card-sub">FullMath.sol • 0 Phantom Overflow</div>
            </div>
            <div class="card">
                <div class="card-label">Mitigation Latency <span>SLA &lt;45ms</span></div>
                <div class="card-val" style="color: var(--accent-cyan);" id="val-latency">28.4 ms</div>
                <div class="card-sub">Flashbots Bundle Relay Speed</div>
            </div>
        </div>

        <div class="pools-grid">
            <div class="pool-card">
                <div class="pool-header">
                    <div>
                        <div class="pool-name">Uniswap v3 (WETH / USDC)</div>
                        <div style="font-size: 11px; color: var(--text-dim); font-family: 'JetBrains Mono';">0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640</div>
                    </div>
                    <span class="status-pill pill-normal" id="pill-uni">HEALTHY</span>
                </div>
                <div class="pool-metrics">
                    <div class="metric-box">
                        <div>RESERVE 0 (WETH)</div>
                        <div id="uni-res0">42,150.00</div>
                    </div>
                    <div class="metric-box">
                        <div>RESERVE 1 (USDC)</div>
                        <div id="uni-res1">138,000,000.00</div>
                    </div>
                    <div class="metric-box">
                        <div>INVARIANT RATIO (K)</div>
                        <div id="uni-k">1.0000 (100%)</div>
                    </div>
                    <div class="metric-box">
                        <div>PROTECTION HOOK</div>
                        <div>Anti-Sybil LP Freeze</div>
                    </div>
                </div>
                <div class="btn-group">
                    <button class="btn-attack" onclick="simulateAttack('Uniswap_v3_WETH_USDC')">⚡ Trigger Flash-Loan Drain (Simulate)</button>
                    <button class="btn-reset" onclick="resetPool('Uniswap_v3_WETH_USDC')">🛡️ Multisig Unpause (Gnosis Safe)</button>
                </div>
            </div>

            <div class="pool-card">
                <div class="pool-header">
                    <div>
                        <div class="pool-name">Aave v3 (Core Market WETH)</div>
                        <div style="font-size: 11px; color: var(--text-dim); font-family: 'JetBrains Mono';">0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2</div>
                    </div>
                    <span class="status-pill pill-normal" id="pill-aave">HEALTHY</span>
                </div>
                <div class="pool-metrics">
                    <div class="metric-box">
                        <div>TOTAL COLLATERAL (WETH)</div>
                        <div id="aave-res0">185,000.00</div>
                    </div>
                    <div class="metric-box">
                        <div>TOTAL BORROWED (WETH)</div>
                        <div id="aave-res1">142,000.00</div>
                    </div>
                    <div class="metric-box">
                        <div>SOLVENCY RATIO</div>
                        <div id="aave-k">1.0000 (130.2% Health)</div>
                    </div>
                    <div class="metric-box">
                        <div>CIRCUIT ACTION</div>
                        <div>Liquidation Halter Active</div>
                    </div>
                </div>
                <div class="btn-group">
                    <button class="btn-attack" onclick="simulateAttack('Aave_v3_WETH_Pool')">⚡ Trigger Collateral Attack (Simulate)</button>
                    <button class="btn-reset" onclick="resetPool('Aave_v3_WETH_Pool')">🛡️ Multisig Unpause (Gnosis Safe)</button>
                </div>
            </div>
        </div>

        <div class="incidents-log">
            <div class="panel-title">📡 Flashbots Defense Telemetry & Incident Audit Trail</div>
            <div id="log-container">
                <div class="log-entry">
                    <span class="log-time">[System Init]</span> Sentinel Bot initialized on Ethereum Mainnet. Connected to Flashbots Protect RPC. Gnosis Safe (3/5) verified. All invariants healthy.
                </div>
            </div>
        </div>
    </div>

    <script>
        async function fetchStatus() {
            try {
                const res = await fetch('/api/status');
                const data = await res.json();
                
                document.getElementById('val-block').innerText = '#' + data.l1Block.toLocaleString();
                document.getElementById('val-basefee').innerText = data.gas.baseFeeGwei + ' Gwei';
                document.getElementById('val-priority').innerText = '+' + data.gas.maxPriorityFeePerGasGwei + ' Gwei Overbid';
                
                // Uniswap
                const uni = data.pools['Uniswap_v3_WETH_USDC'];
                document.getElementById('uni-k').innerText = uni.k_ratio.toFixed(4) + ' (' + (uni.k_ratio*100).toFixed(1) + '%)';
                const pillUni = document.getElementById('pill-uni');
                if (uni.status === 'EMERGENCY_PAUSED') {
                    pillUni.className = 'status-pill pill-paused';
                    pillUni.innerText = 'CIRCUIT BREAKER TRIGGERED';
                } else {
                    pillUni.className = 'status-pill pill-normal';
                    pillUni.innerText = 'HEALTHY';
                }

                // Aave
                const aave = data.pools['Aave_v3_WETH_Pool'];
                document.getElementById('aave-k').innerText = aave.k_ratio.toFixed(4);
                const pillAave = document.getElementById('pill-aave');
                if (aave.status === 'EMERGENCY_PAUSED') {
                    pillAave.className = 'status-pill pill-paused';
                    pillAave.innerText = 'CIRCUIT BREAKER TRIGGERED';
                } else {
                    pillAave.className = 'status-pill pill-normal';
                    pillAave.innerText = 'HEALTHY';
                }
            } catch (e) {
                console.error("Fetch error", e);
            }
        }

        async function simulateAttack(poolKey) {
            const res = await fetch('/api/simulate-attack', {
                method: 'POST',
                headers: {'Content-Type': 'application/json'},
                body: JSON.stringify({pool: poolKey})
            });
            const data = await res.json();
            
            const logBox = document.getElementById('log-container');
            const entry = document.createElement('div');
            entry.className = 'log-entry';
            entry.innerHTML = `
                <span class="log-time">[DEFENSE DISPATCH - ${new Date().toLocaleTimeString()}]</span> 
                <span class="log-drop">DRAIN ATTACK DETECTED (-24.0%)</span> on <b>${data.pool}</b>. 
                Defensive pause dispatched via <span class="log-tx">${data.relay}</span>. 
                Bundle: <code>${data.bundleHash}</code>. 
                Latency: <b>${data.mitigationLatencyMs}ms</b>. 
                State: <i>Emergency Wind Down armed (24h)</i>.
            `;
            logBox.prepend(entry);
            document.getElementById('val-latency').innerText = data.mitigationLatencyMs + ' ms';
            fetchStatus();
        }

        async function resetPool(poolKey) {
            const res = await fetch('/api/reset-pool', {
                method: 'POST',
                headers: {'Content-Type': 'application/json'},
                body: JSON.stringify({pool: poolKey})
            });
            const data = await res.json();
            
            const logBox = document.getElementById('log-container');
            const entry = document.createElement('div');
            entry.className = 'log-entry';
            entry.innerHTML = `
                <span class="log-time">[MULTISIG UNPAUSE - ${new Date().toLocaleTimeString()}]</span> 
                Gnosis Safe 3/5 signature quorum confirmed. Pool <b>${data.pool}</b> reserves recalibrated and unpaused safely.
            `;
            logBox.prepend(entry);
            fetchStatus();
        }

        setInterval(fetchStatus, 3000);
        fetchStatus();
    </script>
</body>
</html>
"""

@app.get("/", response_class=HTMLResponse)
async def serve_dashboard():
    return HTMLResponse(content=HTML_CONTENT)

@app.get("/api/status")
async def get_status():
    return JSONResponse(content=watcher.get_telemetry_state())

@app.post("/api/simulate-attack")
async def trigger_attack(payload: dict):
    pool_key = payload.get("pool", "Uniswap_v3_WETH_USDC")
    result = watcher.simulate_attack_and_mitigate(pool_key)
    return JSONResponse(content=result)

@app.post("/api/reset-pool")
async def reset(payload: dict):
    pool_key = payload.get("pool", "Uniswap_v3_WETH_USDC")
    result = watcher.reset_pool(pool_key)
    return JSONResponse(content=result)

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=5057)
