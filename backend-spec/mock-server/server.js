/**
 * Commercial VPN Control Plane - Mock Backend Server
 * Built with native Node.js (Zero external dependencies).
 * Simulates commercial VPN backend with:
 * - Email Auth (Register, Verify, Login, Refresh, Forgot/Reset)
 * - Subscription & Account state
 * - Global Region & Server dispatch
 * - Short-lived Ephemeral Node Credentials generator (sing-box ready)
 */

const http = require('http');
const https = require('https');
const crypto = require('crypto');
const url = require('url');

const PORT = process.env.PORT || 8080;

const RESEND_API_KEY = process.env.RESEND_API_KEY || "";
const RESEND_FROM = process.env.RESEND_FROM || "AeroVPN <onboarding@resend.dev>";

// Local-dev node credentials via env; never commit production secrets.
// POST /v1/connect injects these per-request (mirrors server-cloud.js).
const NODE_CONFIG = {
  serverIp: process.env.NODE_SERVER_IP || "192.236.235.187",
  hy2Port: parseInt(process.env.NODE_HY2_PORT || "9443", 10),
  hy2Password: process.env.NODE_HY2_PASSWORD || "dev_hy2_password_change_me",
  hy2ObfsPassword: process.env.NODE_HY2_OBFS_PASSWORD || "dev_hy2_obfs_change_me",
  hy2Sni: process.env.NODE_HY2_SNI || "www.ethworldcupcoin.xyz",
  vlessPort: parseInt(process.env.NODE_VLESS_PORT || "443", 10),
  vlessUuid: process.env.NODE_VLESS_UUID || "00000000-0000-4000-8000-000000000000",
  vlessSni: process.env.NODE_VLESS_SNI || "www.cloudflare.com",
  vlessRealityPub: process.env.NODE_VLESS_REALITY_PUB || "dev_reality_pub_change_me",
  vlessRealityShort: process.env.NODE_VLESS_REALITY_SHORT || "0000000000000000",
};

function sendEmailViaResend(toEmail, code) {
  if (!RESEND_API_KEY) {
    console.log(`[MOCK_EMAIL] RESEND_API_KEY not configured. Verification code for ${toEmail} is: ${code}`);
    return Promise.resolve({ id: "mock_resend_" + Date.now(), mock: true });
  }
  return new Promise((resolve, reject) => {
    const postData = JSON.stringify({
      from: RESEND_FROM,
      to: [toEmail],
      subject: "【AeroVPN】您的账号注册验证码",
      html: `
        <div style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; max-width: 500px; margin: 0 auto; padding: 28px; border: 1px solid #eaeaea; border-radius: 12px; background: #ffffff;">
          <div style="text-align: center; margin-bottom: 24px;">
            <h2 style="margin: 0; color: #111827; font-size: 24px; font-weight: 700;">AeroVPN</h2>
            <p style="margin: 6px 0 0; color: #6b7280; font-size: 14px;">极速 · 安全 · 隐私加速通道</p>
          </div>
          <div style="border-top: 1px solid #f3f4f6; padding-top: 20px;">
            <p style="color: #374151; font-size: 15px; margin: 0 0 16px;">您好！</p>
            <p style="color: #374151; font-size: 14px; margin: 0 0 20px; line-height: 1.6;">
              您正在注册 AeroVPN 账号，本次操作的电子邮箱验证码为：
            </p>
            <div style="background: #f8fafc; border: 1px dashed #cbd5e1; border-radius: 8px; padding: 18px; text-align: center; margin: 0 0 24px;">
              <span style="font-size: 34px; font-weight: 800; letter-spacing: 8px; color: #0f172a; font-family: monospace;">${code}</span>
            </div>
            <p style="color: #64748b; font-size: 13px; line-height: 1.6; margin: 0 0 8px;">
              • 验证码有效期为 <strong>15 分钟</strong>，请勿将验证码泄露给他人。<br>
              • 如非您本人操作，请忽略此邮件。
            </p>
          </div>
          <div style="border-top: 1px solid #f3f4f6; margin-top: 24px; padding-top: 16px; text-align: center;">
            <p style="color: #9ca3af; font-size: 12px; margin: 0;">© AeroVPN Global Service. All rights reserved.</p>
          </div>
        </div>
      `,
    });

    const options = {
      hostname: "api.resend.com",
      port: 443,
      path: "/emails",
      method: "POST",
      headers: {
        "Authorization": `Bearer ${RESEND_API_KEY}`,
        "Content-Type": "application/json",
        "Content-Length": Buffer.byteLength(postData),
      },
      timeout: 10000,
    };

    const req = https.request(options, (res) => {
      let respBody = "";
      res.on("data", (chunk) => { respBody += chunk; });
      res.on("end", () => {
        try {
          const parsed = JSON.parse(respBody);
          if (res.statusCode >= 200 && res.statusCode < 300) {
            resolve(parsed);
          } else {
            reject(new Error(parsed.message || `Resend error status ${res.statusCode}`));
          }
        } catch (e) {
          if (res.statusCode >= 200 && res.statusCode < 300) {
            resolve({ raw: respBody });
          } else {
            reject(new Error(`Resend error status ${res.statusCode}: ${respBody}`));
          }
        }
      });
    });

    req.on("error", (err) => { reject(err); });
    req.on("timeout", () => {
      req.destroy();
      reject(new Error("Resend API request timed out"));
    });
    req.write(postData);
    req.end();
  });
}

// In-Memory Database for demonstration & testing
const USERS = new Map();
const SESSIONS = new Map();
const VERIFY_CODES = new Map();



// Region catalog (United States & Japan nodes)
// Display IPs are informational; real creds come from NODE_CONFIG at /connect.
const REGIONS = [
  {
    id: 'us',
    name: 'United States',
    code: 'US',
    flag_emoji: '🇺🇸',
    recommended: true,
    cities: [
      { id: 'us-1', name: '节点 1', latency_ms: 26, load_percent: 15, features: ['streaming', 'ultra_fast', 'hy2'], server_ip: NODE_CONFIG.serverIp, protocol: 'hysteria2' },
    ]
  },
  {
    id: 'jp',
    name: 'Japan',
    code: 'JP',
    flag_emoji: '🇯🇵',
    recommended: true,
    cities: [
      { id: 'jp-1', name: '节点 1', latency_ms: 32, load_percent: 18, features: ['streaming', 'ultra_fast', 'hy2'], server_ip: NODE_CONFIG.serverIp, protocol: 'hysteria2' },
    ]
  }
];

function hashPassword(password, salt) {
  const s = salt || crypto.randomBytes(16).toString('hex');
  const hash = crypto.createHash('sha256').update(s + ':' + password).digest('hex');
  return { salt: s, hash };
}

function verifyPassword(password, user) {
  if (!user) return false;
  if (user.password_hash && !user.password_salt) {
    const legacy = crypto.createHash('sha256').update(password).digest('hex');
    return legacy === user.password_hash;
  }
  if (!user.password_salt || !user.password_hash) return false;
  const check = crypto.createHash('sha256').update(user.password_salt + ':' + password).digest('hex');
  return check === user.password_hash;
}

function generateTokens(user, deviceId = 'dev_default') {
  const sessionId = 'sess_' + crypto.randomBytes(8).toString('hex');
  const accessToken = 'aat_' + crypto.randomBytes(24).toString('hex');
  const refreshToken = 'art_' + crypto.randomBytes(24).toString('hex');

  const session = {
    sessionId,
    userId: user.id,
    email: user.email,
    deviceId,
    accessToken,
    refreshToken,
    expiresAt: Date.now() + 3600 * 1000,
  };
  SESSIONS.set(accessToken, session);
  SESSIONS.set(refreshToken, session);

  return {
    access_token: accessToken,
    refresh_token: refreshToken,
    token_type: 'Bearer',
    expires_in: 3600,
    device_session_id: sessionId,
    user: {
      id: user.id,
      email: user.email,
      plan_status: user.plan.status,
    }
  };
}

function authenticate(req) {
  const authHeader = req.headers['authorization'];
  if (!authHeader || !authHeader.startsWith('Bearer ')) {
    return null;
  }
  const token = authHeader.slice(7).trim();
  const session = SESSIONS.get(token);
  if (!session || session.expiresAt < Date.now()) {
    return null;
  }
  const user = USERS.get(session.email);
  return { user, session };
}

function parseJsonBody(req) {
  return new Promise((resolve, reject) => {
    let body = '';
    req.on('data', chunk => {
      body += chunk;
      if (body.length > 1024 * 1024) req.destroy(); // 1MB limit
    });
    req.on('end', () => {
      try {
        resolve(body ? JSON.parse(body) : {});
      } catch (e) {
        reject(e);
      }
    });
    req.on('error', reject);
  });
}

function sendJson(res, statusCode, data) {
  const payload = JSON.stringify(data);
  res.writeHead(statusCode, {
    'Content-Type': 'application/json',
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type, Authorization',
  });
  res.end(payload);
}

const server = http.createServer(async (req, res) => {
  // CORS Preflight
  if (req.method === 'OPTIONS') {
    res.writeHead(204, {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type, Authorization',
    });
    return res.end();
  }

  const parsedUrl = url.parse(req.url, true);
  const path = parsedUrl.pathname;

  try {
    // Health Check
    if (path === '/health' || path === '/') {
      return sendJson(res, 200, {
        status: 'ok',
        service: 'AeroVPN Commercial Control Plane',
        version: '1.0.0',
        timestamp: Math.floor(Date.now() / 1000)
      });
    }

    // 1. POST /v1/auth/send-code
    if (path === '/v1/auth/send-code' && req.method === 'POST') {
      const { email } = await parseJsonBody(req);
      if (!email || !email.includes('@')) {
        return sendJson(res, 400, { error: '请输入有效的电子邮箱地址' });
      }

      const code = Math.floor(100000 + Math.random() * 900000).toString();
      VERIFY_CODES.set(email, {
        code,
        expiresAt: Date.now() + 15 * 60 * 1000,
      });

      console.log(`[AUTH] Verification code for ${email} is: ${code}`);

      try {
        await sendEmailViaResend(email, code);
        return sendJson(res, 200, {
          code: 0,
          message: '验证码已发送至您的邮箱，请注意查收',
          email
        });
      } catch (err) {
        console.error(`[RESEND_ERR] Failed to send email to ${email}:`, err.message);
        if (err.message && err.message.includes("You can only send testing emails to your own email address")) {
          return sendJson(res, 403, {
            error: "邮件服务当前处于测试模式，仅支持向管理员邮箱发送验证码。若要向任意用户发送，需在 resend.com 验证您的域名（如 ethworldcupcoin.xyz）。",
            details: err.message
          });
        }
        return sendJson(res, 500, {
          error: `邮件发送失败: ${err.message || "未知异常"}`
        });
      }
    }

    // 2. POST /v1/auth/register
    if (path === '/v1/auth/register' && req.method === 'POST') {
      const { email, password, code } = await parseJsonBody(req);
      if (!email || !password || password.length < 6) {
        return sendJson(res, 400, { error: '请输入有效的邮箱和密码（至少6位）' });
      }

      if (!code || code.length < 6) {
        return sendJson(res, 400, { error: '请输入6位邮箱验证码' });
      }

      if (USERS.has(email)) {
        return sendJson(res, 409, { error: '该邮箱已被注册，请直接登录' });
      }

      const pending = VERIFY_CODES.get(email);
      if (!pending || pending.code !== code || pending.expiresAt < Date.now()) {
        return sendJson(res, 400, { error: '验证码错误或已过期，请重新获取' });
      }

      VERIFY_CODES.delete(email);

      // Commercial strict: zero free quota, zero free days, inactive status
      const { salt, hash } = hashPassword(password);
      const newUser = {
        id: 'usr_' + crypto.randomUUID().slice(0, 8),
        email,
        password_salt: salt,
        password_hash: hash,
        verified: true,
        plan: {
          id: 'plan_none',
          name: '未开通会员',
          status: 'expired',
          expires_at: Math.floor(Date.now() / 1000),
          max_devices: 0,
          current_devices: 0,
          traffic_gb: 0.0,
        },
        created_at: Math.floor(Date.now() / 1000),
      };

      USERS.set(email, newUser);
      return sendJson(res, 200, {
        code: 0,
        message: '注册成功，请使用新账号登录',
        email
      });
    }

    // DEPRECATED /v1/auth/verify-email: removed.
    // The canonical flow is send-code -> register (which consumes the code).
    // This stub is kept to return a clear 410 instead of silently creating
    // users from undefined passwords (previous dead code used pending.password).
    if (path === '/v1/auth/verify-email' && req.method === 'POST') {
      return sendJson(res, 410, { error: 'Deprecated. Use /v1/auth/register with email+password+code.' });
    }

    // 3. POST /v1/auth/login
    if (path === '/v1/auth/login' && req.method === 'POST') {
      const { email, password, device_info } = await parseJsonBody(req);
      const user = USERS.get(email);
      if (!user || !verifyPassword(password, user)) {
        return sendJson(res, 401, { error: 'Invalid email or password' });
      }

      const deviceId = (device_info && device_info.device_id) || 'dev_' + crypto.randomUUID().slice(0, 6);
      const tokens = generateTokens(user, deviceId);
      return sendJson(res, 200, tokens);
    }

    // 4. POST /v1/auth/refresh
    if (path === '/v1/auth/refresh' && req.method === 'POST') {
      const { refresh_token } = await parseJsonBody(req);
      const session = SESSIONS.get(refresh_token);
      if (!session) {
        return sendJson(res, 401, { error: 'Invalid refresh token' });
      }
      const user = USERS.get(session.email);
      const newTokens = generateTokens(user, session.deviceId);
      return sendJson(res, 200, newTokens);
    }

    // 5. POST /v1/auth/forgot-password & /v1/auth/reset-password
    // Real code flow (no hardcoded 123456): forgot issues a 6-digit code
    // stored in VERIFY_CODES under `reset:<email>`; reset consumes it.
    if (path === '/v1/auth/forgot-password' && req.method === 'POST') {
      const { email } = await parseJsonBody(req);
      if (!email || !email.includes('@')) {
        return sendJson(res, 400, { error: '请输入有效的电子邮箱地址' });
      }
      const code = Math.floor(100000 + Math.random() * 900000).toString();
      VERIFY_CODES.set('reset:' + email, {
        code,
        expiresAt: Date.now() + 15 * 60 * 1000,
      });
      console.log(`[MOCK EMAIL] Password reset code for ${email} is: ${code} (15min)`);
      try {
        await sendEmailViaResend(email, code);
      } catch (e) {
        console.error('[MOCK EMAIL] Resend failed, code still valid locally:', e.message);
      }
      return sendJson(res, 200, { message: 'Reset code sent to your email' });
    }
    if (path === '/v1/auth/reset-password' && req.method === 'POST') {
      const { email, code, new_password } = await parseJsonBody(req);
      const pending = VERIFY_CODES.get('reset:' + email);
      if (!pending || pending.code !== code || pending.expiresAt < Date.now()) {
        return sendJson(res, 400, { error: 'Invalid or expired reset code' });
      }
      if (!new_password || new_password.length < 6) {
        return sendJson(res, 400, { error: '新密码至少6位' });
      }
      const user = USERS.get(email);
      if (!user) {
        return sendJson(res, 404, { error: 'Account not found' });
      }
      const { salt, hash } = hashPassword(new_password);
      user.password_salt = salt;
      user.password_hash = hash;
      VERIFY_CODES.delete('reset:' + email);
      return sendJson(res, 200, { message: 'Password reset successful. Please log in.' });
    }

    // Protected Routes from here
    const auth = authenticate(req);
    if (!auth) {
      return sendJson(res, 401, { error: 'Unauthorized or token expired' });
    }
    const { user, session } = auth;

    // 6. GET /v1/account
    if (path === '/v1/account' && req.method === 'GET') {
      return sendJson(res, 200, {
        user_id: user.id,
        email: user.email,
        plan: user.plan,
        account_created_at: user.created_at,
      });
    }

    // 7. GET /v1/regions
    if (path === '/v1/regions' && req.method === 'GET') {
      return sendJson(res, 200, { regions: REGIONS });
    }

    // 8. POST /v1/connect
    // The core dispatcher: selects optimal node and returns ephemeral credentials
    if (path === '/v1/connect' && req.method === 'POST') {
      if (user.plan.status !== 'active') {
        return sendJson(res, 403, {
          error: 'Subscription expired or inactive. Please renew your plan.',
          plan_status: user.plan.status,
        });
      }

      const body = await parseJsonBody(req);
      const regionId = body.region_id || 'us';
      const cityId = body.city_id;
      const protocolPref = body.protocol_preference || 'auto';

      const region = REGIONS.find(r => r.id === regionId) || REGIONS[0];
      const city = (cityId && region.cities.find(c => c.id === cityId)) || region.cities[0];

      // Generate ephemeral node specification
      const expiresAt = Math.floor(Date.now() / 1000) + 3600; // 1 hour lease
      const sessionId = 'ephem_' + crypto.randomUUID().slice(0, 8);
      const assignedIp = `198.51.100.${Math.floor(Math.random() * 200 + 10)}`;

      // Choose protocol
      let selectedProtocol = 'vless';
      if (city.protocol) {
        selectedProtocol = city.protocol;
      } else if (protocolPref === 'wireguard' || protocolPref === 'hysteria2' || protocolPref === 'trojan') {
        selectedProtocol = protocolPref;
      }

      // Build node spec from env-backed NODE_CONFIG (no hardcoded production secrets)
      let nodeSpec;
      if (selectedProtocol === 'hysteria2' || city.id === 'us-1' || city.id === 'jp-1' || city.id === 'us-hy2') {
        selectedProtocol = 'hysteria2';
        nodeSpec = {
          server: NODE_CONFIG.serverIp,
          server_port: NODE_CONFIG.hy2Port,
          password: NODE_CONFIG.hy2Password,
          tls: {
            enabled: true,
            server_name: NODE_CONFIG.hy2Sni,
            obfs: {
              type: 'salamander',
              password: NODE_CONFIG.hy2ObfsPassword,
            },
          },
        };
      } else {
        const isRealNode = city.id === 'us-lax' || !city.server_ip || city.server_ip === NODE_CONFIG.serverIp;
        nodeSpec = {
          server: isRealNode ? NODE_CONFIG.serverIp : (city.server_ip || `${city.id}-relay.aerovpn.net`),
          server_port: selectedProtocol === 'wireguard' ? 51820 : 443,
          uuid: isRealNode ? NODE_CONFIG.vlessUuid : crypto.randomUUID(),
          password: crypto.randomBytes(16).toString('hex'),
          flow: selectedProtocol === 'vless' ? 'xtls-rprx-vision' : undefined,
          tls: {
            enabled: true,
            server_name: isRealNode ? NODE_CONFIG.vlessSni : 'gateway.cloudflare.com',
            reality: selectedProtocol === 'vless' ? {
              public_key: isRealNode ? NODE_CONFIG.vlessRealityPub : 'b9k7L_1oBqvG6fRz2X3mNk7l8P9q0R1s2T3u4V5w6X8',
              short_id: isRealNode ? NODE_CONFIG.vlessRealityShort : crypto.randomBytes(4).toString('hex'),
            } : undefined,
          },
          wireguard: selectedProtocol === 'wireguard' ? {
            private_key: crypto.randomBytes(32).toString('base64'),
            public_key: 'h2K9L9mP7q8R9s0T1u2V3w4X5y6Z7a8B9c0D1e2F3g=',
            address: ['10.66.66.2/32', 'fd00::2/128'],
            reserved: [0, 0, 0],
          } : undefined,
        };
      }

      return sendJson(res, 200, {
        session_id: sessionId,
        region_id: region.id,
        city_id: city.id,
        city_name: city.name,
        country_name: region.name,
        country_code: region.code,
        virtual_ip: assignedIp,
        expires_at: expiresAt,
        ttl_seconds: 3600,
        protocol: selectedProtocol,
        node_spec: nodeSpec,
      });
    }

    // 9. GET /v1/devices
    if (path === '/v1/devices' && req.method === 'GET') {
      return sendJson(res, 200, {
        devices: [
          {
            session_id: session.sessionId,
            device_name: 'Windows Desktop Client',
            os: 'Windows 11',
            last_active_at: Math.floor(Date.now() / 1000),
            is_current: true,
          }
        ]
      });
    }

    // 10. POST /v1/devices/revoke
    if (path === '/v1/devices/revoke' && req.method === 'POST') {
      const { device_session_id } = await parseJsonBody(req);
      return sendJson(res, 200, { success: true, revoked_id: device_session_id });
    }

    // Not Found
    return sendJson(res, 404, { error: 'Endpoint not found' });
  } catch (err) {
    console.error('Server error:', err);
    return sendJson(res, 500, { error: 'Internal server error', details: err.message });
  }
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`=======================================================`);
  console.log(` AeroVPN Mock Control Plane running on http://127.0.0.1:${PORT}`);
  console.log(` No demo accounts are pre-seeded (commercial strict mode).`);
  console.log(` Register via POST /v1/auth/send-code -> /v1/auth/register.`);
  console.log(`=======================================================`);
});
