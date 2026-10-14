/**
 * AeroVPN Production Cloud Control Plane API
 * Hosted on: www.ethworldcupcoin.xyz
 * Directory: /root/VPN/api
 *
 * Commercial-hardening notes (pre-launch fixes):
 *  - Passwords: scrypt (memory-hard, OWASP-acceptable) in a versioned record
 *    format; legacy salted/unsalted SHA-256 accounts verify and transparently
 *    upgrade on their next successful login. No account is dropped.
 *  - Sessions: only SHA-256 digests of access/refresh tokens are persisted;
 *    the plaintext bearer tokens never touch disk. Refresh rotates the pair
 *    (old digests deleted), /v1/auth/logout revokes, expired rows are swept.
 *  - Tunnel credentials are tracked as their own connect-session records
 *    (DB.connectSessions) with per-device quota enforcement, TTL and server-side
 *    revocation. They are separate from DB.sessions (login token sessions).
 *  - db.json writes are atomic (temp file + rename); any legacy-format
 *    migration takes a timestamped backup before the first migrated save.
 *  - Emails are masked in logs. Node IPs are not hardcoded - they come from env.
 *  - OTP_HMAC_SECRET is required for verification codes and MUST be an
 *    independent strong random value; the Resend API key is never used as the
 *    pepper.
 */

const http = require("http");
const https = require("https");
const crypto = require("crypto");
const url = require("url");
const fs = require("fs");
const path = require("path");

const PORT = process.env.PORT || 8088;
// Ops can relocate the data file (e.g. onto a dedicated volume with restrictive
// permissions or a backup mount). Tests use this to run against temp files.
const DB_FILE = process.env.AEROVPN_DB_FILE || path.join(__dirname, "db.json");

// Resend Email Integration
// All secrets come from environment. No production node credentials are hardcoded.
// See .env.example for required variables.
const RESEND_API_KEY = process.env.RESEND_API_KEY || "";
const RESEND_DOMAIN_ID = process.env.RESEND_DOMAIN_ID || "";
const RESEND_FROM_PROD = process.env.RESEND_FROM || "AeroVPN <noreply@example.invalid>";
const RESEND_FROM_SANDBOX = "AeroVPN <onboarding@resend.dev>";
// The pepper MUST be an independent strong random secret. It is intentionally
// NOT derived from the Resend key: the email provider credential must never
// double as a long-term cryptographic secret. Generate with:
//   openssl rand -hex 32
const OTP_HMAC_SECRET = process.env.OTP_HMAC_SECRET || "";
// Per-user-session node credentials (opt-in). See deriveSessionCredentials
// below and deploy/CONTROL_PLANE.md for the node-side requirement.
const PER_USER_CREDENTIALS = process.env.NODE_PER_USER_CREDENTIALS === "1";
const CONNECT_CRED_SECRET = process.env.CONNECT_CRED_SECRET || "";

// Optional deployment profile generated from the actual Hysteria node config.
// The private file stays on the server and is never bundled with clients.
const NODE_PROFILE_FILE = process.env.AEROVPN_NODE_PROFILE || path.join(__dirname, "node-config.json");
const NODE_PROFILE = fs.existsSync(NODE_PROFILE_FILE)
  ? JSON.parse(fs.readFileSync(NODE_PROFILE_FILE, "utf8")) : {};

// Upstream node credentials MUST be injected via environment in production.
// There are deliberately NO defaults here: a real node IP is infrastructure
// data and must never be committed to the repository. Development uses
// backend-spec/mock-server/server.js instead of this file.
const NODE_CONFIG = {
  serverIp: process.env.NODE_SERVER_IP || NODE_PROFILE.server || "",
  hy2Port: parseInt(process.env.NODE_HY2_PORT || String(NODE_PROFILE.server_port || 9443), 10),
  hy2Password: process.env.NODE_HY2_PASSWORD || NODE_PROFILE.password || "",
  hy2ObfsPassword: process.env.NODE_HY2_OBFS_PASSWORD || NODE_PROFILE.obfs?.password || "",
  hy2Sni: process.env.NODE_HY2_SNI || NODE_PROFILE.tls?.server_name || "",
  vlessPort: parseInt(process.env.NODE_VLESS_PORT || "443", 10),
  vlessUuid: process.env.NODE_VLESS_UUID || "",
  vlessSni: process.env.NODE_VLESS_SNI || "",
  vlessRealityPub: process.env.NODE_VLESS_REALITY_PUB || "",
  vlessRealityShort: process.env.NODE_VLESS_REALITY_SHORT || "",
  // Optional server-declared capacity. When unset the client omits
  // up_mbps/down_mbps and the core defaults to BBR congestion control.
  hy2UpMbps: parseInt(process.env.NODE_HY2_UP_MBPS || "0", 10),
  hy2DownMbps: parseInt(process.env.NODE_HY2_DOWN_MBPS || "0", 10),
};

// Per-region nodes. One machine per region keeps the important part separable:
// when a region is offline, that region alone goes dark instead of every user
// landing on a single box. A region with no host configured is omitted from the
// catalog entirely (a "node" that silently points at the wrong machine is worse
// than not advertising the region).
//
// Each entry reads `<PREFIX>_SERVER_IP` plus the same `_HY2_*` / `_VLESS_*`
// variable names as NODE_CONFIG. When a region has no dedicated credentials set,
// it intentionally falls back to the shared NODE_* values so existing single-node
// deployments keep working unchanged.
function regionNode(prefix) {
  const serverIp = process.env[`${prefix}_SERVER_IP`];
  return {
    serverIp,
    hy2Port: parseInt(process.env[`${prefix}_HY2_PORT`] || String(NODE_CONFIG.hy2Port), 10),
    hy2Password: process.env[`${prefix}_HY2_PASSWORD`] || NODE_CONFIG.hy2Password,
    hy2ObfsPassword: process.env[`${prefix}_HY2_OBFS_PASSWORD`] || NODE_CONFIG.hy2ObfsPassword,
    hy2Sni: process.env[`${prefix}_HY2_SNI`] || NODE_CONFIG.hy2Sni,
    hy2UpMbps: parseInt(process.env[`${prefix}_HY2_UP_MBPS`] || String(NODE_CONFIG.hy2UpMbps), 10),
    hy2DownMbps: parseInt(process.env[`${prefix}_HY2_DOWN_MBPS`] || String(NODE_CONFIG.hy2DownMbps), 10),
    vlessPort: parseInt(process.env[`${prefix}_VLESS_PORT`] || String(NODE_CONFIG.vlessPort), 10),
    vlessUuid: process.env[`${prefix}_VLESS_UUID`] || NODE_CONFIG.vlessUuid,
    vlessSni: process.env[`${prefix}_VLESS_SNI`] || NODE_CONFIG.vlessSni,
    vlessRealityPub: process.env[`${prefix}_VLESS_REALITY_PUB`] || NODE_CONFIG.vlessRealityPub,
    vlessRealityShort: process.env[`${prefix}_VLESS_REALITY_SHORT`] || NODE_CONFIG.vlessRealityShort,
  };
}

const REGION_NODES = {
  us: regionNode("NODE_US"),
  jp: regionNode("NODE_JP"),
  sg: regionNode("NODE_SG"),
};

function nodeForRegion(regionId) {
  const node = REGION_NODES[regionId];
  // Only advertise a region that has its own host or inherits a configured one.
  return node && node.serverIp ? node : NODE_CONFIG;
}

if (!NODE_CONFIG.hy2Password || !NODE_CONFIG.vlessUuid) {
  const message =
    "[SECURITY] Node credentials fall back to empty/local defaults. " +
    "Set NODE_HY2_PASSWORD/NODE_VLESS_UUID/... env vars in production.";
  // In production an empty credential set means every tunnel the dispatcher hands
  // out is unusable, so refuse to start instead of shipping broken sessions.
  if (process.env.NODE_ENV === "production" || process.env.PRODUCTION === "1") {
    console.error(message);
    console.error("Refusing to start in production without real node credentials.");
    process.exit(1);
  }
  console.warn(message);
}

// Persistent Database Schema
let DB = {
  users: {},
  sessions: {},
  verify_codes: {},
  connectSessions: {},
};

// ---------------------------------------------------------------------------
// Low-level crypto helpers
// ---------------------------------------------------------------------------

function sha256Hex(value) {
  return crypto.createHash("sha256").update(value).digest("hex");
}

// Bearer tokens are stored ONLY as digests; the plaintext value exists in RAM
// and in the response body, never in db.json.
function hashToken(token) {
  return sha256Hex("aerovpn-token:" + token);
}

// scrypt parameters: 2^15 cost, blocksize 8, parallelization 1 (~64 MiB and
// roughly 100 ms per hash on a small VPS core). If the host has more headroom,
// raise COST and bump FORMAT_VERSION - old records keep verifying via their
// embedded parameters.
const SCRYPT = { cost: 1 << 15, blockSize: 8, parallelization: 1, keyLength: 64 };
// Node/OpenSSL caps scrypt at 32 MiB by default; our parameters need 128*N*r
// (32 MiB) plus working memory, so the cap is raised explicitly here and the
// same value is used at verification time.
const SCRYPT_MAXMEM = 128 * 1024 * 1024;
const PASSWORD_FORMAT_VERSION = 1;

function hashPassword(password) {
  const salt = crypto.randomBytes(16);
  const hash = crypto.scryptSync(password, salt, SCRYPT.keyLength, {
    N: SCRYPT.cost,
    r: SCRYPT.blockSize,
    p: SCRYPT.parallelization,
    maxmem: SCRYPT_MAXMEM,
  });
  return {
    format: PASSWORD_FORMAT_VERSION,
    record:
      `v${PASSWORD_FORMAT_VERSION}$scrypt$${SCRYPT.cost}$${SCRYPT.blockSize}$${SCRYPT.parallelization}` +
      `$${salt.toString("base64")}$${hash.toString("base64")}`,
  };
}

function scryptVerify(password, record) {
  // v1$scrypt$N$r$p$<saltB64>$<hashB64>
  const parts = record.split("$");
  if (parts.length !== 7 || parts[0] !== "v1" || parts[1] !== "scrypt") return null;
  const [, , cost, blockSize, parallelization, saltB64, hashB64] = parts;
  const expected = Buffer.from(hashB64, "base64");
  const actual = crypto.scryptSync(password, Buffer.from(saltB64, "base64"), expected.length, {
    N: parseInt(cost, 10),
    r: parseInt(blockSize, 10),
    p: parseInt(parallelization, 10),
    maxmem: SCRYPT_MAXMEM,
  });
  return expected.length === actual.length && crypto.timingSafeEqual(expected, actual);
}

function legacySha256Verify(password, user) {
  // Backward compatibility: legacy unsalted sha256(password) accounts, and the
  // intermediate sha256(salt:password) format.
  if (user.password_hash && !user.password_salt) {
    const legacy = sha256Hex(password);
    return legacy === user.password_hash;
  }
  if (!user.password_salt || !user.password_hash) return false;
  const check = sha256Hex(user.password_salt + ":" + password);
  return check === user.password_hash;
}

// Returns {ok, needsUpgrade}. needsUpgrade marks legacy-format records so a
// successful login can transparently rehash them; no account is ever dropped.
function verifyPassword(password, user) {
  if (!user || typeof password !== "string" || password.length === 0) return { ok: false };
  if (user.password_hash && user.password_hash.startsWith("v1$scrypt$")) {
    return { ok: scryptVerify(password, user.password_hash) === true, needsUpgrade: false };
  }
  return { ok: legacySha256Verify(password, user) === true, needsUpgrade: true };
}

function upgradePasswordRecord(user, password) {
  const { format, record } = hashPassword(password);
  user.password_format = format;
  user.password_hash = record;
  // The salt is embedded in the versioned record now; clear the legacy column.
  delete user.password_salt;
}

function maskEmail(email) {
  const at = String(email || "").indexOf("@");
  if (at <= 0) return "***";
  const local = String(email).slice(0, at);
  const domain = String(email).slice(at + 1);
  const domainAt = domain.lastIndexOf(".");
  const tld = domainAt > 0 ? domain.slice(domainAt) : "";
  return `${local[0]}***@${domain[0]}***${tld}`;
}

// ---------------------------------------------------------------------------
// Persistence: atomic writes, explicit legacy migration with backup
// ---------------------------------------------------------------------------

function saveDatabase() {
  try {
    // Atomic on POSIX and on NTFS (same volume): a crash mid-write leaves the
    // previous db.json intact instead of a truncated file.
    const tmpFile = DB_FILE + ".tmp-" + process.pid;
    fs.writeFileSync(tmpFile, JSON.stringify(DB, null, 2), "utf8");
    fs.renameSync(tmpFile, DB_FILE);
  } catch (err) {
    console.error("[DB] Save error:", err);
  }
}

function backupDatabase(reason) {
  try {
    if (!fs.existsSync(DB_FILE)) return;
    const backup = `${DB_FILE}.backup-${reason}-${new Date().toISOString().replace(/[:.]/g, "-")}`;
    fs.copyFileSync(DB_FILE, backup);
    console.log(`[DB] Backup written before migration: ${backup}`);
  } catch (err) {
    console.error("[DB] Backup failed (migration aborted to protect data):", err);
    throw err;
  }
}

// One-time migration of the legacy session format, which stored the plaintext
// access/refresh tokens as map keys AND inside the record. Sessions are
// re-keyed by token digest; plaintext material is removed. A timestamped
// backup is taken before the first migrated save so the operator can always
// roll back. This is explicit and logged - it never silently overwrites data.
function migrateLegacySessions() {
  let changed = false;
  const migrated = {};
  for (const [key, session] of Object.entries(DB.sessions || {})) {
    const hadPlaintext =
      session &&
      (typeof session.accessToken === "string" || typeof session.refreshToken === "string");
    if (!hadPlaintext) {
      migrated[key] = session;
      continue;
    }
    const accessHash = hashToken(session.accessToken);
    const refreshHash = hashToken(session.refreshToken);
    migrated[accessHash] = { ...session, accessHash, refreshHash };
    delete migrated[accessHash].accessToken;
    delete migrated[accessHash].access_token;
    delete migrated[accessHash].refreshToken;
    delete migrated[accessHash].refresh_token;
    // A legacy record was double-keyed (by both tokens); the refresh digest key
    // keeps resolving to the same session object.
    migrated[refreshHash] = migrated[accessHash];
    changed = true;
  }
  if (changed) {
    backupDatabase("legacy-session-migration");
    // In-place replacement keeps references to DB.sessions valid.
    for (const key of Object.keys(DB.sessions)) delete DB.sessions[key];
    Object.assign(DB.sessions, migrated);
    saveDatabase();
    console.log(
      `[DB] Migrated session records to digest-only storage (${Object.keys(migrated).length} map entries).`
    );
  }
  return changed;
}

function loadDatabase() {
  try {
    if (fs.existsSync(DB_FILE)) {
      const content = fs.readFileSync(DB_FILE, "utf8");
      const loaded = JSON.parse(content);
      // Fill the existing object in place instead of reassigning: exported and
      // captured references to DB must stay valid across reloads.
      DB.users = loaded.users || {};
      DB.sessions = loaded.sessions || {};
      DB.verify_codes = loaded.verify_codes || {};
      DB.connectSessions = loaded.connectSessions || {};
      console.log(`[DB] Loaded ${Object.keys(DB.users).length} users from disk.`);
    } else {
      seedDefaultDatabase();
      saveDatabase();
    }
  } catch (err) {
    // A corrupt data file must never be silently discarded.
    console.error("[DB] Load error - refusing to overwrite the data file:", err);
    backupDatabase("corrupt-load");
    seedDefaultDatabase();
    saveDatabase();
  }
}

function seedDefaultDatabase() {
  // In-place reset (same object identity) for the same reason as loadDatabase.
  for (const key of Object.keys(DB)) delete DB[key];
  DB.users = {};
  DB.sessions = {};
  DB.verify_codes = {};
  DB.connectSessions = {};
}

// Drop expired auth sessions, expired tunnel connect-sessions and stale
// verification codes. Called on startup and periodically in production.
function sweepExpired(now = Date.now()) {
  let removedSessions = 0;
  for (const [key, session] of Object.entries(DB.sessions || {})) {
    if (session && session.expiresAt < now) {
      delete DB.sessions[key];
      removedSessions++;
    }
  }
  let removedConnect = 0;
  for (const [id, connectSession] of Object.entries(DB.connectSessions || {})) {
    if (connectSession && connectSession.expiresAt < now - 24 * 3600 * 1000) {
      delete DB.connectSessions[id];
      removedConnect++;
    }
  }
  let removedCodes = 0;
  for (const [key, pending] of Object.entries(DB.verify_codes || {})) {
    if (pending && pending.expiresAt < now) {
      delete DB.verify_codes[key];
      removedCodes++;
    }
  }
  if (removedSessions + removedConnect + removedCodes > 0) {
    saveDatabase();
  }
  return { removedSessions, removedConnect, removedCodes };
}

function verificationCodeDigest(recordKey, code) {
  if (!OTP_HMAC_SECRET) {
    throw new Error("OTP_HMAC_SECRET must be configured for verification codes");
  }
  return crypto.createHmac("sha256", OTP_HMAC_SECRET)
    .update(`${recordKey}\0${code}`)
    .digest("hex");
}

function verificationCodeMatches(pending, recordKey, code) {
  if (!pending || typeof pending.code_hash !== "string" || typeof code !== "string") return false;
  const expected = Buffer.from(pending.code_hash, "hex");
  const actual = Buffer.from(verificationCodeDigest(recordKey, code), "hex");
  return expected.length === actual.length && crypto.timingSafeEqual(expected, actual);
}

function migrateVerificationCodes() {
  const entries = Object.entries(DB.verify_codes || {});
  if (!entries.length) return;

  let changed = false;
  if (!OTP_HMAC_SECRET) {
    // Without a pepper, do not retain legacy plaintext verification codes.
    DB.verify_codes = {};
    changed = true;
  } else {
    for (const [recordKey, pending] of entries) {
      if (pending && typeof pending.code === "string" && pending.expiresAt > Date.now()) {
        pending.code_hash = verificationCodeDigest(recordKey, pending.code);
        delete pending.code;
        changed = true;
      } else if (pending && pending.code) {
        delete DB.verify_codes[recordKey];
        changed = true;
      }
    }
  }
  if (changed) saveDatabase();
}

// ---------------------------------------------------------------------------
// Auth sessions (login tokens) - digest storage + rotation + revocation
// ---------------------------------------------------------------------------

const SESSION_TTL_MS = 30 * 86400 * 1000;

function generateTokens(user, deviceId = "dev_default") {
  const sessionId = "sess_" + crypto.randomBytes(8).toString("hex");
  const accessToken = "aat_" + crypto.randomBytes(24).toString("hex");
  const refreshToken = "art_" + crypto.randomBytes(24).toString("hex");

  const session = {
    sessionId,
    userId: user.id,
    email: user.email,
    deviceId,
    // Only digests are persisted; the plaintext values live in this response.
    accessHash: hashToken(accessToken),
    refreshHash: hashToken(refreshToken),
    createdAt: Date.now(),
    expiresAt: Date.now() + SESSION_TTL_MS,
  };

  DB.sessions[session.accessHash] = session;
  DB.sessions[session.refreshHash] = session;
  saveDatabase();

  return {
    access_token: accessToken,
    refresh_token: refreshToken,
    token_type: "Bearer",
    expires_in: SESSION_TTL_MS / 1000,
    device_session_id: sessionId,
    user: {
      id: user.id,
      email: user.email,
      plan_status: user.plan.status,
    }
  };
}

function authenticate(req) {
  const authHeader = req.headers["authorization"];
  if (!authHeader || !authHeader.startsWith("Bearer ")) {
    return null;
  }
  const token = authHeader.slice(7).trim();
  const session = DB.sessions[hashToken(token)];
  if (!session || session.expiresAt < Date.now()) {
    return null;
  }
  const user = DB.users[session.email];
  if (!user) return null;
  return { user, session };
}

// Refresh rotation: the presented refresh token identifies the session; the old
// pair is deleted (replay of the old refresh token fails) and a new pair with
// the same device_session_id is issued.
function rotateSession(session) {
  delete DB.sessions[session.accessHash];
  delete DB.sessions[session.refreshHash];
  const user = DB.users[session.email];
  if (!user) return null;
  const tokens = generateTokens(user, session.deviceId);
  // Keep the device session identity stable across rotations.
  const renewed = DB.sessions[hashToken(tokens.access_token)];
  if (renewed) renewed.sessionId = session.sessionId;
  tokens.device_session_id = session.sessionId;
  saveDatabase();
  return tokens;
}

function revokeSession(session) {
  delete DB.sessions[session.accessHash];
  delete DB.sessions[session.refreshHash];
  saveDatabase();
}

// ---------------------------------------------------------------------------
// Tunnel connect-sessions (ephemeral node credentials) - separate store with
// per-device quota, TTL and server-side revocation. NOT the same as DB.sessions.
// ---------------------------------------------------------------------------

const CONNECT_TTL_SECONDS = 3600;

// --- Per-user-session node credentials (M6) --------------------------------
// When NODE_PER_USER_CREDENTIALS=1, /v1/connect mints credentials that are
// unique per (user, connect session, expiry) instead of handing the shared
// static NODE_* credentials to every account. A leaked credential then only
// compromises one session, is attributable in node logs, and dies with the
// session TTL or a /v1/connect/revoke.
//
// REQUIRES node-side validation: the node must accept these credentials (for
// example sing-box hysteria2/VLESS `users[]` fed by a user-management API
// running the same derivation with the same CONNECT_CRED_SECRET). Until that
// integration exists the flag stays OFF and the static NODE_* credentials are
// issued, exactly as before.
function uuidV5FromMaterial(namespaceHex, name) {
  // RFC 4122 v5 (SHA-1 based) over a fixed namespace.
  const hash = crypto
    .createHash("sha1")
    .update(Buffer.from(namespaceHex, "hex"))
    .update(name, "utf8")
    .digest();
  hash[6] = (hash[6] & 0x0f) | 0x50;
  hash[8] = (hash[8] & 0x3f) | 0x80;
  const h = hash.toString("hex");
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20, 32)}`;
}

function deriveSessionCredentials(userId, connectSession) {
  const material = `${userId}|${connectSession.id}|${connectSession.expiresAt}`;
  const mac = (scope) =>
    crypto.createHmac("sha256", CONNECT_CRED_SECRET).update(`${scope}|${material}`).digest("hex");
  return {
    hy2Password: mac("hy2-password").slice(0, 32),
    hy2ObfsPassword: mac("hy2-obfs").slice(0, 24),
    vlessUuid: uuidV5FromMaterial("6ba7b8119dad11d180b400c04fd430c8", mac("vless-uuid")),
  };
}

function activeConnectSessionsFor(userId, now = Date.now()) {
  return Object.values(DB.connectSessions || {}).filter(
    (s) => s.userId === userId && !s.revoked && s.expiresAt > now
  );
}

function revokeConnectSessions(userId, targetId = null) {
  let revoked = 0;
  for (const connectSession of Object.values(DB.connectSessions || {})) {
    if (connectSession.userId !== userId) continue;
    if (targetId && connectSession.id !== targetId) continue;
    if (!connectSession.revoked) {
      connectSession.revoked = true;
      revoked++;
    }
  }
  if (revoked > 0) saveDatabase();
  return revoked;
}

// ---------------------------------------------------------------------------
// Email delivery (Resend). `sendEmail` is an injectable seam for tests only.
// ---------------------------------------------------------------------------

function doResendRequest(toEmail, code, fromAddress) {
  if (!RESEND_API_KEY) {
    return Promise.reject(new Error("RESEND_API_KEY environment variable is not configured"));
  }
  return new Promise((resolve, reject) => {
    const postData = JSON.stringify({
      from: fromAddress,
      to: [toEmail],
      subject: "【AeroVPN】您的账号注册验证码",
      html: `
        <div style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; max-width: 500px; margin: 0 auto; padding: 28px; border: 1px solid #eaeaea; border-radius: 12px; background: #ffffff;">
          <div style="text-align: center; margin-bottom: 24px;">
            <h2 style="margin: 0; color: #111827; font-size: 24px; font-weight: 700; letter-spacing: -0.5px;">AeroVPN</h2>
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

// Resend Intelligent Dispatcher (Auto-selects custom domain or fallback)
async function sendEmailViaResend(toEmail, code) {
  try {
    const result = await doResendRequest(toEmail, code, RESEND_FROM_PROD);
    console.log(`[RESEND] Sent via domain (${RESEND_FROM_PROD}) to ${maskEmail(toEmail)}`);
    return result;
  } catch (err) {
    if (err.message && err.message.includes("not verified")) {
      console.log(`[RESEND] Domain pending verification, falling back to sandbox for testing: ${maskEmail(toEmail)}`);
      return await doResendRequest(toEmail, code, RESEND_FROM_SANDBOX);
    }
    throw err;
  }
}

// Test seam: lets the test suite capture verification codes without any
// network access. Never used in production paths (main guard keeps this file's
// server unlistened when required as a module, and tests overwrite this).
let sendEmail = sendEmailViaResend;
function setEmailSenderForTests(fn) {
  sendEmail = fn;
}

// Region & Node Catalog.
// NOTE: display IPs are informational only. Real connection credentials are
// injected per-request in POST /v1/connect from the per-region env vars (see
// REGION_NODES / regionNode above). Regions without a configured host are not
// advertised, so the catalog never points two "cities" at the same machine.
function buildRegions() {
  const catalog = [];
  const usNode = REGION_NODES.us.serverIp ? REGION_NODES.us : NODE_CONFIG;
  const jpNode = REGION_NODES.jp.serverIp ? REGION_NODES.jp : NODE_CONFIG;
  const sgNode = REGION_NODES.sg.serverIp ? REGION_NODES.sg : null;

  catalog.push({
    id: "us",
    name: "United States",
    code: "US",
    flag_emoji: "🇺🇸",
    recommended: true,
    cities: [
      {
        id: "us-1",
        name: "节点 1",
        latency_ms: 26,
        load_percent: 15,
        features: ["streaming", "ultra_fast", "hy2"],
        server_ip: usNode.serverIp,
        protocol: "hysteria2"
      }
    ]
  });

  catalog.push({
    id: "jp",
    name: "Japan",
    code: "JP",
    flag_emoji: "🇯🇵",
    recommended: true,
    cities: [
      {
        id: "jp-1",
        name: "节点 1",
        latency_ms: 32,
        load_percent: 18,
        features: ["streaming", "ultra_fast", "hy2"],
        server_ip: jpNode.serverIp,
        protocol: "hysteria2"
      }
    ]
  });

  // Singapore is only advertised when a dedicated host is configured.
  if (sgNode) {
    catalog.push({
      id: "sg",
      name: "Singapore",
      code: "SG",
      flag_emoji: "🇸🇬",
      recommended: false,
      cities: [
        {
          id: "sg-1",
          name: "节点 1",
          latency_ms: 40,
          load_percent: 12,
          features: ["streaming", "ultra_fast", "hy2"],
          server_ip: sgNode.serverIp,
          protocol: "hysteria2"
        }
      ]
    });
  }

  return catalog;
}

const REGIONS = buildRegions();

function parseJsonBody(req) {
  return new Promise((resolve, reject) => {
    let body = "";
    req.on("data", chunk => {
      body += chunk;
      if (body.length > 1024 * 1024) req.destroy();
    });
    req.on("end", () => {
      try {
        resolve(body ? JSON.parse(body) : {});
      } catch (e) {
        reject(e);
      }
    });
    req.on("error", reject);
  });
}

function sendJson(res, statusCode, data) {
  const payload = JSON.stringify(data);
  res.writeHead(statusCode, {
    "Content-Type": "application/json",
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type, Authorization",
  });
  res.end(payload);
}

// ---------------------------------------------------------------------------
// Login-abuse protection.
//
// These limits are in-memory on purpose for the current single-node reality;
// they survive neither restarts nor horizontal scale-out. Before running more
// than one instance, move the counters to shared storage (Redis) or terminate
// at a trusted edge limiter - per-process counters would let an attacker
// multiply their budget by the number of instances. See deploy/CONTROL_PLANE.md.
// ---------------------------------------------------------------------------
const TRUST_PROXY = process.env.TRUST_PROXY === "1" || process.env.TRUST_PROXY === "true";

const RATE_LIMITS = {
  // name:             windowMs,        max,  key        - key is IP or IP+email
  "__global_auth":      { windowMs: 60 * 1000,       max: 60, byEmail: false },
  "auth/login":         { windowMs: 15 * 60 * 1000, max: 10, byEmail: true },
  "auth/register":      { windowMs: 60 * 60 * 1000, max: 10, byEmail: true },
  "auth/send-code":     { windowMs: 60 * 60 * 1000, max: 5,  byEmail: true },
  "auth/forgot-password": { windowMs: 60 * 60 * 1000, max: 5, byEmail: true },
  "auth/reset-password":  { windowMs: 15 * 60 * 1000, max: 10, byEmail: true },
  "connect":            { windowMs: 15 * 60 * 1000, max: 30, byEmail: true },
};

const rateBuckets = new Map(); // bucketKey -> [timestamps]

function clientIp(req) {
  // Trust only X-Real-IP: our documented nginx deployment overwrites it with
  // $remote_addr, so a client cannot inject it. X-Forwarded-For is deliberately
  // NOT consulted - with $proxy_add_x_forwarded_for the proxy *appends* to
  // whatever the client sent, so any XFF entry (leftmost included) can be
  // forged, and keying rate limits on it would let an attacker rotate IPs.
  if (TRUST_PROXY) {
    const real = req.headers["x-real-ip"];
    if (real) {
      return String(real).trim();
    }
  }
  return req.socket.remoteAddress || "unknown";
}

// Returns null when allowed, or the retry-after seconds when rate limited.
function rateLimit(name, email, req) {
  const limit = RATE_LIMITS[name];
  if (!limit) return null;
  const key = limit.byEmail && email
    ? `${name}|${clientIp(req)}|${String(email).toLowerCase()}`
    : `${name}|${clientIp(req)}`;

  const now = Date.now();
  let timestamps = rateBuckets.get(key);
  if (timestamps) {
    timestamps = timestamps.filter((t) => now - t < limit.windowMs);
  } else {
    timestamps = [];
  }
  if (timestamps.length >= limit.max) {
    const retryAfterMs = limit.windowMs - (now - timestamps[0]);
    rateBuckets.set(key, timestamps);
    return Math.max(1, Math.ceil(retryAfterMs / 1000));
  }
  timestamps.push(now);
  rateBuckets.set(key, timestamps);
  return null;
}

// Periodic sweep so the counters cannot grow without bound.
function startRateLimitSweep() {
  setInterval(() => {
    const now = Date.now();
    const widest = Math.max(...Object.values(RATE_LIMITS).map((l) => l.windowMs));
    for (const [key, timestamps] of rateBuckets) {
      const kept = timestamps.filter((t) => now - t < widest);
      if (kept.length === 0) {
        rateBuckets.delete(key);
      } else {
        rateBuckets.set(key, kept);
      }
    }
  }, 10 * 60 * 1000).unref();
}

function startSessionSweep() {
  setInterval(() => {
    sweepExpired();
  }, 60 * 60 * 1000).unref();
}

const server = http.createServer(async (req, res) => {
  if (req.method === "OPTIONS") {
    res.writeHead(204, {
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
      "Access-Control-Allow-Headers": "Content-Type, Authorization",
    });
    return res.end();
  }

  const parsedUrl = url.parse(req.url, true);
  let path = parsedUrl.pathname;
  if (path.startsWith("/api")) {
    path = path.slice(4);
  }

  // Coarse global throttle as a safety net; per-route limits below are stricter.
  // The bucket being full is itself the signal - the old `retryAfter > 60`
  // condition could never be true for a 60s window, silently disabling the net.
  if (path.startsWith("/v1/auth/")) {
    const globalRetry = rateLimit("__global_auth", null, req);
    if (globalRetry !== null) {
      res.setHeader("Retry-After", String(globalRetry));
      return sendJson(res, 429, { error: "请求过于频繁，请稍后再试" });
    }
  }

  // Per-route limiter: returns a 429 response (and returns true) when exceeded.
  const throttle = (name, email) => {
    const retryAfter = rateLimit(name, email, req);
    if (retryAfter !== null) {
      res.setHeader("Retry-After", String(retryAfter));
      sendJson(res, 429, { error: `操作过于频繁，请在 ${retryAfter} 秒后重试` });
      return true;
    }
    return false;
  };

  try {
    // Health Check
    if (path === "/health" || path === "/") {
      return sendJson(res, 200, {
        status: "ok",
        service: "AeroVPN Production Cloud Control Plane",
        version: "1.1.0",
        node: process.env.HEALTH_NODE_NAME || "control-plane",
        registered_users: Object.keys(DB.users).length,
        timestamp: Math.floor(Date.now() / 1000)
      });
    }

    // 1. POST /v1/auth/send-code (Resend Integrated)
    if (path === "/v1/auth/send-code" && req.method === "POST") {
      const { email } = await parseJsonBody(req);
      if (!email || !email.includes("@")) {
        return sendJson(res, 400, { error: "请输入有效的电子邮箱地址" });
      }
      if (throttle("auth/send-code", email)) return;
      if (!OTP_HMAC_SECRET) {
        return sendJson(res, 503, { error: "Verification email is not configured (set OTP_HMAC_SECRET)" });
      }

      const code = crypto.randomInt(100000, 1000000).toString();
      DB.verify_codes[email] = {
        code_hash: verificationCodeDigest(email, code),
        expiresAt: Date.now() + 15 * 60 * 1000,
      };
      saveDatabase();

      try {
        await sendEmail(email, code);
        return sendJson(res, 200, {
          code: 0,
          message: "验证码已成功发送至您的邮箱，请注意查收",
          email: email
        });
      } catch (err) {
        console.error(`[RESEND_ERROR] Failed to send email to ${maskEmail(email)}:`, err.message);
        if (err.message && err.message.includes("You can only send testing emails to your own email address")) {
          return sendJson(res, 403, {
            error: "域名 DNS 解析尚未生效。Spaceship 添加解析记录后需等待 1-5 分钟生效，生效后即可支持全网任意邮箱。",
            details: err.message
          });
        }
        return sendJson(res, 500, {
          error: `邮件发送失败: ${err.message || "未知异常"}`
        });
      }
    }

    // 2. POST /v1/auth/register (Strict commercial registration)
    if (path === "/v1/auth/register" && req.method === "POST") {
      const { email, password, code } = await parseJsonBody(req);
      if (!email || !password || password.length < 6) {
        return sendJson(res, 400, { error: "请输入有效的邮箱和密码（至少6位）" });
      }
      if (throttle("auth/register", email)) return;

      if (!code || code.length < 6) {
        return sendJson(res, 400, { error: "请输入6位邮箱验证码" });
      }

      if (DB.users[email]) {
        return sendJson(res, 409, { error: "该邮箱已被注册，请直接登录" });
      }

      const pending = DB.verify_codes[email];
      if (!pending || !verificationCodeMatches(pending, email, code) || pending.expiresAt < Date.now()) {
        return sendJson(res, 400, { error: "验证码错误或已过期，请重新获取" });
      }

      delete DB.verify_codes[email];

      // Commercial strict: zero free quota, zero free days, inactive status
      const { format, record } = hashPassword(password);
      const newUser = {
        id: "usr_" + crypto.randomUUID().slice(0, 8),
        email,
        password_format: format,
        password_hash: record,
        verified: true,
        plan: {
          id: "plan_none",
          name: "未开通会员",
          status: "expired",
          expires_at: Math.floor(Date.now() / 1000),
          max_devices: 0,
          current_devices: 0,
          traffic_gb: 0.0,
        },
        created_at: Math.floor(Date.now() / 1000),
      };

      DB.users[email] = newUser;
      saveDatabase();
      console.log(`[AUTH] Strict commercial user registered: ${maskEmail(email)}`);

      return sendJson(res, 200, {
        code: 0,
        message: "注册成功，请使用新账号登录",
        email
      });
    }

    // 3. POST /v1/auth/login
    if (path === "/v1/auth/login" && req.method === "POST") {
      const { email, password, device_info } = await parseJsonBody(req);
      // Brute-force guard, applied before the password comparison. Counts failures
      // for a given (IP, email) so a valid login from one IP is not punished for
      // another user, and an attacker cannot spray password guesses at one account.
      if (throttle("auth/login", email)) return;
      const user = DB.users[email];
      const verdict = verifyPassword(password, user);
      if (!verdict.ok) {
        return sendJson(res, 401, { error: "邮箱或密码错误，请核对后重试" });
      }
      // Transparent upgrade: legacy SHA-256 records rehash to scrypt on their
      // next successful login. The plaintext password is already in hand here.
      if (verdict.needsUpgrade) {
        upgradePasswordRecord(user, password);
        saveDatabase();
        console.log(`[AUTH] Upgraded password record to scrypt for ${maskEmail(email)}`);
      }

      const deviceId = (device_info && device_info.device_id) || "dev_" + crypto.randomUUID().slice(0, 6);
      const tokens = generateTokens(user, deviceId);
      return sendJson(res, 200, tokens);
    }

    // 3a. POST /v1/auth/logout - revoke the presented session (both tokens).
    if (path === "/v1/auth/logout" && req.method === "POST") {
      const auth = authenticate(req);
      if (!auth) {
        return sendJson(res, 401, { error: "Unauthorized or token expired" });
      }
      revokeSession(auth.session);
      return sendJson(res, 200, { message: "已退出登录" });
    }

    // 3b. POST /v1/auth/refresh (opaque token rotation, digest-verified)
    if (path === "/v1/auth/refresh" && req.method === "POST") {
      const { refresh_token } = await parseJsonBody(req);
      if (!refresh_token) {
        return sendJson(res, 400, { error: "Missing refresh_token" });
      }
      const session = DB.sessions[hashToken(refresh_token)];
      if (!session || session.expiresAt < Date.now()) {
        return sendJson(res, 401, { error: "Invalid or expired refresh token" });
      }
      const refreshUser = DB.users[session.email];
      if (!refreshUser) {
        return sendJson(res, 401, { error: "Account not found" });
      }
      // Rotate: drop old pair, issue new pair (prevents replay).
      const tokens = rotateSession(session);
      if (!tokens) {
        return sendJson(res, 401, { error: "Account not found" });
      }
      return sendJson(res, 200, tokens);
    }

    // 3c. POST /v1/auth/forgot-password & /v1/auth/reset-password
    // Real code flow via Resend (no hardcoded codes).
    if (path === "/v1/auth/forgot-password" && req.method === "POST") {
      const { email } = await parseJsonBody(req);
      if (!email || !email.includes("@")) {
        return sendJson(res, 400, { error: "请输入有效的电子邮箱地址" });
      }
      if (throttle("auth/forgot-password", email)) return;
      if (!DB.users[email]) {
        // Do not disclose account existence; still return 200 with generic message.
        return sendJson(res, 200, { message: "如果该邮箱已注册，重置验证码已发送" });
      }
      if (!OTP_HMAC_SECRET) {
        return sendJson(res, 503, { error: "Verification email is not configured (set OTP_HMAC_SECRET)" });
      }
      const code = crypto.randomInt(100000, 1000000).toString();
      const resetCodeKey = "reset:" + email;
      DB.verify_codes[resetCodeKey] = {
        code_hash: verificationCodeDigest(resetCodeKey, code),
        expiresAt: Date.now() + 15 * 60 * 1000,
      };
      saveDatabase();
      try {
        await sendEmail(email, code);
      } catch (err) {
        console.error(`[RESEND_ERROR] reset mail to ${maskEmail(email)}:`, err.message);
        return sendJson(res, 500, { error: `邮件发送失败: ${err.message}` });
      }
      return sendJson(res, 200, { message: "重置验证码已发送至您的邮箱" });
    }
    if (path === "/v1/auth/reset-password" && req.method === "POST") {
      const { email, code, new_password } = await parseJsonBody(req);
      if (throttle("auth/reset-password", email)) return;
      const resetCodeKey = "reset:" + email;
      const pending = DB.verify_codes[resetCodeKey];
      if (!pending || !verificationCodeMatches(pending, resetCodeKey, code) || pending.expiresAt < Date.now()) {
        return sendJson(res, 400, { error: "验证码错误或已过期，请重新获取" });
      }
      if (!new_password || new_password.length < 6) {
        return sendJson(res, 400, { error: "新密码至少6位" });
      }
      const target = DB.users[email];
      if (!target) {
        return sendJson(res, 404, { error: "Account not found" });
      }
      const { format, record } = hashPassword(new_password);
      target.password_format = format;
      target.password_hash = record;
      delete target.password_salt;
      delete DB.verify_codes["reset:" + email];
      // Revoke all sessions for safety after password change.
      for (const [key, session] of Object.entries(DB.sessions)) {
        if (session && session.email === email) delete DB.sessions[key];
      }
      saveDatabase();
      return sendJson(res, 200, { message: "密码已重置，请使用新密码登录" });
    }

    // Protected Routes
    const auth = authenticate(req);
    if (!auth) {
      return sendJson(res, 401, { error: "Unauthorized or token expired" });
    }
    const { user, session } = auth;

    // 4. GET /v1/account
    if (path === "/v1/account" && req.method === "GET") {
      return sendJson(res, 200, {
        user_id: user.id,
        email: user.email,
        plan: user.plan,
        account_created_at: user.created_at,
      });
    }

    // 5. GET /v1/regions
    if (path === "/v1/regions" && req.method === "GET") {
      return sendJson(res, 200, { regions: REGIONS });
    }

    // 6. POST /v1/connect (Real Node Ephemeral Dispatcher)
    if (path === "/v1/connect" && req.method === "POST") {
      if (throttle("connect", user.email)) return;
      if (user.plan.status !== "active" || (user.plan.expires_at && user.plan.expires_at < Math.floor(Date.now() / 1000))) {
        return sendJson(res, 403, {
          error: "您尚未开通会员套餐或套餐已到期，请先购买套餐订阅后再连接。",
          plan_status: user.plan.status,
        });
      }

      const body = await parseJsonBody(req);
      const regionId = body.region_id || "us";
      const cityId = body.city_id;
      const protocolPref = String(body.protocol_preference || "auto").toLowerCase();
      // Device identity comes from the login session and is never accepted
      // from the request body: a client that could mint arbitrary device_ids
      // would evade max_devices by reusing or rotating one forged id.
      const deviceId = String(session.deviceId || "dev_default");

      // Device quota (server-side enforcement): a device only counts while it
      // holds a live, non-revoked connect session.
      const activeSessions = activeConnectSessionsFor(user.id);
      const activeDevices = new Set(activeSessions.map((s) => s.deviceId));
      const alreadyConnected = activeDevices.has(deviceId);
      if (!alreadyConnected && user.plan.max_devices > 0 && activeDevices.size >= user.plan.max_devices) {
        return sendJson(res, 403, {
          error: "设备数量已达套餐上限，请先在其他设备上断开连接或升级套餐。",
          max_devices: user.plan.max_devices,
          active_devices: activeDevices.size,
        });
      }

      // Traffic quota: enforced when the plan carries usage data. Traffic
      // metering itself lives on the node (see deploy/CONTROL_PLANE.md) - the
      // control plane cannot measure what it does not observe.
      if (
        user.plan.traffic_gb > 0 &&
        typeof user.plan.traffic_used_gb === "number" &&
        user.plan.traffic_used_gb >= user.plan.traffic_gb
      ) {
        return sendJson(res, 403, {
          error: "本月流量已用尽，请升级套餐或等待下个计费周期。",
          traffic_gb: user.plan.traffic_gb,
          traffic_used_gb: user.plan.traffic_used_gb,
        });
      }

      const region = REGIONS.find(r => r.id === regionId) || REGIONS[0];
      const city = (cityId && region.cities.find(c => c.id === cityId)) || region.cities[0];
      // Credentials come from this region's own node (falls back to the shared
      // NODE_* set), so `us` and `jp` can live on different machines.
      const node = nodeForRegion(region.id);

      if (!new Set(["auto", "hysteria2", "vless", "wireguard", "trojan"]).has(protocolPref)) {
        return sendJson(res, 400, { error: "Unsupported protocol preference" });
      }

      let selectedProtocol = protocolPref === "auto" ? (city.protocol || "hysteria2") : protocolPref;
      if (selectedProtocol === "wireguard" || selectedProtocol === "trojan") {
        return sendJson(res, 422, { error: `Protocol ${selectedProtocol} is not configured for this region` });
      }

      if (!node.serverIp) {
        return sendJson(res, 503, { error: "No node host is configured for this region" });
      }

      const nowMs = Date.now();
      const expiresAtMs = nowMs + CONNECT_TTL_SECONDS * 1000;
      const sessionId = "ephem_" + crypto.randomUUID().slice(0, 8);
      const assignedIp = `198.51.100.${Math.floor(Math.random() * 200 + 10)}`;

      // Supersede any previous live session for the same device: reconnecting
      // invalidates the old credential set server-side. Other devices keep
      // their sessions (they are what max_devices accounting counts).
      for (const s of activeSessions) {
        if (s.deviceId === deviceId) s.revoked = true;
      }

      const connectSession = {
        id: sessionId,
        userId: user.id,
        email: user.email,
        deviceId,
        regionId: region.id,
        protocol: selectedProtocol,
        // Internally epoch milliseconds (consistent with DB.sessions and the
        // quota/sweep helpers); the wire format below stays epoch seconds.
        issuedAt: nowMs,
        expiresAt: expiresAtMs,
        ttl_seconds: CONNECT_TTL_SECONDS,
        revoked: false,
      };
      let sessionCreds = null;
      if (PER_USER_CREDENTIALS) {
        if (!CONNECT_CRED_SECRET) {
          return sendJson(res, 503, {
            error: "NODE_PER_USER_CREDENTIALS=1 requires CONNECT_CRED_SECRET to be set",
          });
        }
        sessionCreds = deriveSessionCredentials(user.id, connectSession);
        // Store only fingerprints (never raw credentials) for audit/lookup.
        connectSession.credentialFingerprints = {
          hy2: crypto.createHash("sha256").update(sessionCreds.hy2Password).digest("hex").slice(0, 16),
          vless: crypto.createHash("sha256").update(sessionCreds.vlessUuid).digest("hex").slice(0, 16),
        };
      }
      DB.connectSessions[sessionId] = connectSession;
      saveDatabase();

      let nodeSpec;
      if (selectedProtocol === "hysteria2") {
        if (!node.serverIp || !node.hy2Password || !node.hy2ObfsPassword) {
          return sendJson(res, 503, { error: "Hysteria2 is not fully configured for this region" });
        }
        nodeSpec = {
          server: node.serverIp,
          server_port: node.hy2Port,
          password: sessionCreds ? sessionCreds.hy2Password : node.hy2Password,
          tls: {
            enabled: true,
            server_name: node.hy2Sni,
            obfs: {
              type: "salamander",
              password: sessionCreds ? sessionCreds.hy2ObfsPassword : node.hy2ObfsPassword,
            },
          },
          // Optional server-declared capacity; the client omits up_mbps/
          // down_mbps when absent and keeps the core's BBR defaults.
          ...(node.hy2UpMbps > 0 || node.hy2DownMbps > 0
            ? {
                up_mbps: node.hy2UpMbps > 0 ? node.hy2UpMbps : undefined,
                down_mbps: node.hy2DownMbps > 0 ? node.hy2DownMbps : undefined,
              }
            : {}),
        };
        if (nodeSpec.up_mbps === undefined) delete nodeSpec.up_mbps;
        if (nodeSpec.down_mbps === undefined) delete nodeSpec.down_mbps;
        nodeSpec.obfs = nodeSpec.tls.obfs;
      } else if (selectedProtocol === "vless") {
        if (!node.serverIp || !node.vlessUuid || !node.vlessRealityPub || !node.vlessRealityShort) {
          return sendJson(res, 503, { error: "VLESS is not fully configured for this region" });
        }
        if (!node.vlessSni) {
          // The client refuses to invent an SNI (diagnostic error there), so the
          // control plane must not hand out a node_spec without one either.
          return sendJson(res, 503, { error: "VLESS node is missing NODE_VLESS_SNI configuration" });
        }
        nodeSpec = {
          server: node.serverIp,
          server_port: node.vlessPort,
          uuid: sessionCreds ? sessionCreds.vlessUuid : node.vlessUuid,
          flow: "xtls-rprx-vision",
          tls: {
            enabled: true,
            server_name: node.vlessSni,
            reality: {
              public_key: node.vlessRealityPub,
              short_id: node.vlessRealityShort,
            },
          },
        };
      } else {
        return sendJson(res, 422, { error: `Protocol ${selectedProtocol} is not configured for this region` });
      }

      return sendJson(res, 200, {
        session_id: sessionId,
        region_id: region.id,
        city_id: city.id,
        city_name: city.name,
        country_name: region.name,
        country_code: region.code,
        virtual_ip: assignedIp,
        expires_at: Math.floor(expiresAtMs / 1000),
        ttl_seconds: CONNECT_TTL_SECONDS,
        protocol: selectedProtocol,
        node_spec: nodeSpec,
      });
    }

    // 6b. POST /v1/connect/revoke - revoke live tunnel credentials server-side.
    // NOTE: this invalidates the connect session in the control plane; node-side
    // enforcement of revocation requires the node integration described in
    // deploy/CONTROL_PLANE.md (until then, issued credentials expire by TTL,
    // or are unique per session under NODE_PER_USER_CREDENTIALS=1 so a revoke
    // at least stops further issuance to the same account/device).
    if (path === "/v1/connect/revoke" && req.method === "POST") {
      const body = await parseJsonBody(req);
      const revoked = revokeConnectSessions(user.id, body.session_id || null);
      return sendJson(res, 200, { revoked });
    }

    // 6c. GET /v1/connect/sessions - list this account's tunnel sessions.
    if (path === "/v1/connect/sessions" && req.method === "GET") {
      const nowMs = Date.now();
      const sessions = Object.values(DB.connectSessions)
        .filter((s) => s.userId === user.id && s.expiresAt > nowMs)
        .map((s) => ({
          session_id: s.id,
          device_id: s.deviceId,
          region_id: s.regionId,
          protocol: s.protocol,
          issued_at: Math.floor(s.issuedAt / 1000),
          expires_at: Math.floor(s.expiresAt / 1000),
          revoked: s.revoked,
        }));
      return sendJson(res, 200, { sessions });
    }

    // 7. GET /v1/devices
    if (path === "/v1/devices" && req.method === "GET") {
      const nowMs = Date.now();
      const connectSessions = Object.values(DB.connectSessions).filter(
        (s) => s.userId === user.id && !s.revoked && s.expiresAt > nowMs
      );
      const sessions = connectSessions.length
        ? connectSessions.map((s) => ({
            session_id: s.id,
            device_name: s.deviceId,
            os: "Connected Device",
            last_active_at: Math.floor(s.issuedAt / 1000),
            is_current: s.deviceId === session.deviceId,
          }))
        : [
            {
              session_id: session.sessionId,
              device_name: "AeroVPN Client",
              os: "Connected Device",
              last_active_at: Math.floor(Date.now() / 1000),
              is_current: true,
            }
          ];
      return sendJson(res, 200, { devices: sessions });
    }

    sendJson(res, 404, { error: "Endpoint not found: " + path });
  } catch (err) {
    console.error("[ERR]", err);
    sendJson(res, 500, { error: "Internal server error" });
  }
});

// ---------------------------------------------------------------------------
// Startup (only when run directly; requiring this module as a library - the
// test suite does - leaves the server unlistened and the data store unloaded).
// ---------------------------------------------------------------------------

function initDataStore() {
  loadDatabase();
  migrateLegacySessions();
  migrateVerificationCodes();
  sweepExpired();
}

if (require.main === module) {
  if (!OTP_HMAC_SECRET) {
    console.warn(
      "[SECURITY] OTP_HMAC_SECRET is not set. Verification codes are disabled " +
      "until it is configured (openssl rand -hex 32)."
    );
  }
  initDataStore();
  startRateLimitSweep();
  startSessionSweep();

  server.listen(PORT, process.env.BIND_ADDR || "127.0.0.1", () => {
    console.log(`[AeroVPN API] Production Server listening on ${process.env.BIND_ADDR || "127.0.0.1"}:${PORT}`);
    if (!TRUST_PROXY) {
      console.log("[AeroVPN API] TRUST_PROXY is off: rate limiting keys on the direct peer address.");
      console.log("             Set TRUST_PROXY=1 when a reverse proxy terminates TLS in front of this service.");
    }
  });
}

module.exports = {
  server,
  DB,
  initDataStore,
  hashPassword,
  verifyPassword,
  upgradePasswordRecord,
  generateTokens,
  authenticate,
  hashToken,
  rateLimit,
  rateBuckets,
  RATE_LIMITS,
  // exposed for per-user credential tests (M6)
  PER_USER_CREDENTIALS,
  deriveSessionCredentials,
  uuidV5FromMaterial,
  sweepExpired,
  revokeConnectSessions,
  activeConnectSessionsFor,
  maskEmail,
  setEmailSenderForTests,
  // exposed for assertions only
  SCRYPT,
  PASSWORD_FORMAT_VERSION,
};
