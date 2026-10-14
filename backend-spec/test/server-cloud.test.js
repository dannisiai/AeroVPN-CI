/**
 * Regression tests for the AeroVPN production control plane hardening.
 * Run with: node --test backend-spec/test/
 *
 * The suite drives the real HTTP server on an ephemeral port against a temp
 * db.json. No external network calls: the Resend sender is replaced with a
 * capture stub via setEmailSenderForTests().
 */

const test = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const crypto = require("node:crypto");

const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "aerovpn-api-test-"));
const DB_FILE = path.join(tmpDir, "db.json");

process.env.AEROVPN_DB_FILE = DB_FILE;
process.env.NODE_ENV = "test";
process.env.OTP_HMAC_SECRET = crypto.randomBytes(32).toString("hex");
process.env.RESEND_API_KEY = "";
// Node credentials so /v1/connect can issue real specs (TEST-NET documentation
// values; they are never dialed by the control plane).
process.env.NODE_SERVER_IP = "203.0.113.10";
process.env.NODE_HY2_PORT = "9443";
process.env.NODE_HY2_PASSWORD = "hy2pass";
process.env.NODE_HY2_OBFS_PASSWORD = "obfspass";
process.env.NODE_HY2_SNI = "hy2.example.net";
process.env.NODE_VLESS_PORT = "443";
process.env.NODE_VLESS_UUID = "b831381d-6324-4d53-ad4f-8cda48b30811";
process.env.NODE_VLESS_SNI = "vless.example.net";
process.env.NODE_VLESS_REALITY_PUB = "pubkey";
process.env.NODE_VLESS_REALITY_SHORT = "abcd";

const cp = require("../server-cloud.js");
const { server, initDataStore, rateLimit, rateBuckets, RATE_LIMITS } = cp;

initDataStore();

let capturedCode = null;
cp.setEmailSenderForTests(async (toEmail, code) => {
  capturedCode = code;
  return { id: "test" };
});

let baseUrl = "";
test.before(async () => {
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  baseUrl = `http://127.0.0.1:${server.address().port}`;
});

test.after(() => new Promise((resolve) => server.close(resolve)));

async function request(method, pathname, body, token) {
  const headers = { "Content-Type": "application/json" };
  if (token) headers["Authorization"] = `Bearer ${token}`;
  const res = await fetch(baseUrl + pathname, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  let json = null;
  try { json = await res.json(); } catch (_) {}
  return { status: res.status, body: json };
}

async function registerAndLogin(email, password, deviceId = "dev_test") {
  await request("POST", "/v1/auth/send-code", { email });
  assert.ok(capturedCode, "verification code must be captured by the test sender");
  const reg = await request("POST", "/v1/auth/register", { email, password, code: capturedCode });
  assert.strictEqual(reg.status, 200, `register failed: ${JSON.stringify(reg.body)}`);
  return loginAs(email, password, deviceId);
}

async function loginAs(email, password, deviceId = "dev_test") {
  const login = await request("POST", "/v1/auth/login", { email, password, device_info: { device_id: deviceId } });
  assert.strictEqual(login.status, 200, `login failed: ${JSON.stringify(login.body)}`);
  return login.body;
}

function activatePlan(email, overrides = {}) {
  const user = cp.DB.users[email];
  Object.assign(user.plan, {
    status: "active",
    expires_at: Math.floor(Date.now() / 1000) + 30 * 86400,
    max_devices: 2,
    traffic_gb: 0,
    ...overrides,
  });
  cp.DB && fs.writeFileSync(DB_FILE, JSON.stringify(cp.DB));
}

test("password hashing is scrypt with a versioned record format", async () => {
  const email = "scrypt@example.com";
  await registerAndLogin(email, "correct horse battery staple");
  const user = cp.DB.users[email];
  assert.ok(user.password_hash.startsWith(`v${cp.PASSWORD_FORMAT_VERSION}$scrypt$`),
    "stored record must be a versioned scrypt record");
  assert.strictEqual(user.password_format, cp.PASSWORD_FORMAT_VERSION);
  assert.strictEqual(user.password_salt, undefined, "legacy salt column must be cleared");
  const verdict = cp.verifyPassword("correct horse battery staple", user);
  assert.strictEqual(verdict.ok, true);
  assert.strictEqual(cp.verifyPassword("wrong password", user).ok, false);
});

test("legacy unsalted sha256 accounts log in and transparently upgrade to scrypt", async () => {
  const email = "legacy@example.com";
  const password = "oldpassword";
  cp.DB.users[email] = {
    id: "usr_legacy1",
    email,
    verified: true,
    password_hash: crypto.createHash("sha256").update(password).digest("hex"),
    plan: { id: "p", name: "n", status: "expired", expires_at: 0, max_devices: 0, current_devices: 0, traffic_gb: 0 },
    created_at: 0,
  };
  const login = await request("POST", "/v1/auth/login", { email, password, device_info: { device_id: "dev_legacy" } });
  assert.strictEqual(login.status, 200, "legacy account must still be able to log in");
  assert.ok(cp.DB.users[email].password_hash.startsWith("v1$scrypt$"),
    "successful login must upgrade the record to scrypt");
  const again = await request("POST", "/v1/auth/login", { email, password, device_info: { device_id: "dev_legacy" } });
  assert.strictEqual(again.status, 200, "login must keep working after upgrade");
});

test("legacy salted sha256 accounts log in and upgrade", async () => {
  const email = "legacy2@example.com";
  const password = "hunter22";
  const salt = crypto.randomBytes(16).toString("hex");
  cp.DB.users[email] = {
    id: "usr_legacy2",
    email,
    verified: true,
    password_salt: salt,
    password_hash: crypto.createHash("sha256").update(salt + ":" + password).digest("hex"),
    plan: { id: "p", name: "n", status: "expired", expires_at: 0, max_devices: 0, current_devices: 0, traffic_gb: 0 },
    created_at: 0,
  };
  const login = await request("POST", "/v1/auth/login", { email, password, device_info: { device_id: "dev_legacy2" } });
  assert.strictEqual(login.status, 200);
  assert.ok(cp.DB.users[email].password_hash.startsWith("v1$scrypt$"));
});

test("tokens are never persisted in plaintext and auth works via digest lookup", async () => {
  const email = "tokens@example.com";
  const tokens = await registerAndLogin(email, "supersecret99", "dev_tok");
  const raw = fs.readFileSync(DB_FILE, "utf8");
  assert.ok(!raw.includes(tokens.access_token), "access token must not appear in the database file");
  assert.ok(!raw.includes(tokens.refresh_token), "refresh token must not appear in the database file");
  assert.ok(!raw.includes("accessToken") && !raw.includes("refreshToken"),
    "legacy plaintext fields must be gone from the session records");

  const me = await request("GET", "/v1/account", undefined, tokens.access_token);
  assert.strictEqual(me.status, 200);
});

test("refresh rotates the pair; the old refresh token stops working; logout revokes", async () => {
  const email = "rotate@example.com";
  const tokens = await registerAndLogin(email, "rotatepass1", "dev_rot");

  const refreshed = await request("POST", "/v1/auth/refresh", { refresh_token: tokens.refresh_token });
  assert.strictEqual(refreshed.status, 200);
  assert.notStrictEqual(refreshed.body.access_token, tokens.access_token);
  assert.strictEqual(refreshed.body.device_session_id, tokens.device_session_id,
    "rotation keeps the device session id stable");

  // Old pair is dead.
  const oldAccess = await request("GET", "/v1/account", undefined, tokens.access_token);
  assert.strictEqual(oldAccess.status, 401, "old access token must be invalid after rotation");
  const replay = await request("POST", "/v1/auth/refresh", { refresh_token: tokens.refresh_token });
  assert.strictEqual(replay.status, 401, "replaying the old refresh token must fail");

  // New pair works, then logout revokes it.
  const me = await request("GET", "/v1/account", undefined, refreshed.body.access_token);
  assert.strictEqual(me.status, 200);
  const logout = await request("POST", "/v1/auth/logout", {}, refreshed.body.access_token);
  assert.strictEqual(logout.status, 200);
  const afterLogout = await request("GET", "/v1/account", undefined, refreshed.body.access_token);
  assert.strictEqual(afterLogout.status, 401, "logout must revoke the whole session");
});

test("connect enforces plan expiry, device quota and traffic quota; sessions are separate from auth sessions", async () => {
  const email = "quota@example.com";
  const tokens = await registerAndLogin(email, "quotapass1", "dev_A");
  activatePlan(email, { max_devices: 1 });

  // Expired plan first.
  const user = cp.DB.users[email];
  const savedExpiry = user.plan.expires_at;
  user.plan.status = "expired";
  const denied = await request("POST", "/v1/connect", { region_id: "us", device_id: "dev_A" }, tokens.access_token);
  assert.strictEqual(denied.status, 403, "expired plan must not connect");
  user.plan.status = "active";
  user.plan.expires_at = savedExpiry;

  // First device connects.
  const first = await request("POST", "/v1/connect", { region_id: "us", device_id: "dev_A" }, tokens.access_token);
  assert.strictEqual(first.status, 200, `connect failed: ${JSON.stringify(first.body)}`);
  assert.strictEqual(first.body.node_spec.server, "203.0.113.10");
  assert.strictEqual(first.body.ttl_seconds, 3600);

  // Regression: device identity is bound to the login session. A forged
  // device_id in the connect body must be ignored, not mint a new device slot.
  const forged = await request("POST", "/v1/connect", { region_id: "us", device_id: "dev_evil" }, tokens.access_token);
  assert.strictEqual(forged.status, 200, "same-session reconnect must not be quota-blocked");
  assert.strictEqual(
    cp.DB.connectSessions[forged.body.session_id].deviceId,
    "dev_A",
    "connect body device_id must never override the login session's device"
  );

  // Second device is over max_devices=1. It cannot appear by asserting a new
  // device_id on the same token - it must hold its own login session.
  const tokensB = await loginAs(email, "quotapass1", "dev_B");
  const second = await request("POST", "/v1/connect", { region_id: "us", device_id: "dev_B" }, tokensB.access_token);
  assert.strictEqual(second.status, 403, "over-quota device must be rejected server-side");

  // Traffic quota structure.
  activatePlan(email, { max_devices: 2, traffic_gb: 10, traffic_used_gb: 10 });
  const noTraffic = await request("POST", "/v1/connect", { region_id: "us", device_id: "dev_B" }, tokens.access_token);
  assert.strictEqual(noTraffic.status, 403, "exhausted traffic quota must be rejected");
  activatePlan(email, { traffic_gb: 0, traffic_used_gb: undefined });

  // Reconnect from the same device supersedes (not duplicates) and does not
  // count as a second device.
  const reconnect = await request("POST", "/v1/connect", { region_id: "us", device_id: "dev_A" }, tokens.access_token);
  assert.strictEqual(reconnect.status, 200);
  assert.notStrictEqual(reconnect.body.session_id, first.body.session_id);

  // Connect sessions live in their own store, distinct from cp.DB.sessions.
  const connectSession = cp.DB.connectSessions[reconnect.body.session_id];
  assert.ok(connectSession, "connect session must be recorded in cp.DB.connectSessions");
  assert.strictEqual(connectSession.userId, user.id);
  assert.strictEqual(typeof connectSession.revoked, "boolean");
  const listed = await request("GET", "/v1/connect/sessions", undefined, tokens.access_token);
  assert.strictEqual(listed.status, 200);
  assert.ok(listed.body.sessions.some((s) => s.session_id === reconnect.body.session_id));
});

test("revoke invalidates live connect sessions server-side", async () => {
  const email = "revoke@example.com";
  const tokens = await registerAndLogin(email, "revokepass1", "dev_R");
  activatePlan(email, { max_devices: 2 });

  const conn = await request("POST", "/v1/connect", { region_id: "us", device_id: "dev_R" }, tokens.access_token);
  assert.strictEqual(conn.status, 200);

  const revoked = await request("POST", "/v1/connect/revoke", { session_id: conn.body.session_id }, tokens.access_token);
  assert.strictEqual(revoked.status, 200);
  assert.ok(revoked.body.revoked >= 1);

  const listed = await request("GET", "/v1/connect/sessions", undefined, tokens.access_token);
  const entry = listed.body.sessions.find((s) => s.session_id === conn.body.session_id);
  assert.strictEqual(entry.revoked, true, "revoked session must be flagged");

  // The device slot is freed: connecting again is allowed and revocation of the
  // old session does not block issuance of new credentials.
  const again = await request("POST", "/v1/connect", { region_id: "us", device_id: "dev_R" }, tokens.access_token);
  assert.strictEqual(again.status, 200);
});

test("connect endpoint is rate limited per account", () => {
  const fakeReq = { socket: { remoteAddress: "192.0.2.77" }, headers: {} };
  const key = "connect";
  for (let i = 0; i < RATE_LIMITS[key].max; i++) {
    const r = rateLimit(key, "rl@example.com", fakeReq);
    assert.strictEqual(r, null, `attempt ${i + 1} must be allowed`);
  }
  const blocked = rateLimit(key, "rl@example.com", fakeReq);
  assert.strictEqual(typeof blocked, "number", "the attempt over the limit must be throttled");
  rateBuckets.clear();
});

test("global auth throttle engages when its bucket is full (regression: retryAfter > 60 never fired)", () => {
  const fakeReq = { socket: { remoteAddress: "192.0.2.78" }, headers: {} };
  const limit = RATE_LIMITS["__global_auth"];
  for (let i = 0; i < limit.max; i++) {
    rateLimit("__global_auth", null, fakeReq);
  }
  const blocked = rateLimit("__global_auth", null, fakeReq);
  assert.strictEqual(typeof blocked, "number",
    "a full 60s bucket must block immediately; the old handler condition never triggered");
  rateBuckets.clear();
});

test("sweepExpired removes expired auth sessions, connect sessions and codes", () => {
  const now = Date.now();
  cp.DB.sessions["deadhash"] = { sessionId: "s", userId: "u", email: "x@y.z", deviceId: "d", accessHash: "deadhash", refreshHash: "r", createdAt: 0, expiresAt: now - 1000 };
  cp.DB.connectSessions["deadconnect"] = { id: "deadconnect", userId: "u", deviceId: "d", issuedAt: 0, expiresAt: Math.floor(now / 1000) - 25 * 3600, revoked: false };
  cp.DB.verify_codes["stale@example.com"] = { code_hash: "aa", expiresAt: now - 1000 };
  const result = cp.sweepExpired(now);
  assert.ok(result.removedSessions >= 1);
  assert.ok(result.removedConnect >= 1);
  assert.ok(result.removedCodes >= 1);
  assert.strictEqual(cp.DB.sessions["deadhash"], undefined);
  assert.strictEqual(cp.DB.connectSessions["deadconnect"], undefined);
});

test("db.json writes are atomic and leave no temp files behind", () => {
  const files = fs.readdirSync(tmpDir).filter((f) => f.startsWith("db.json.tmp-"));
  assert.deepStrictEqual(files, [], "no temp write files may remain after saves");
  const parsed = JSON.parse(fs.readFileSync(DB_FILE, "utf8"));
  assert.ok(parsed.users && parsed.sessions && parsed.connectSessions);
});

test("legacy db.json (plaintext tokens) is migrated explicitly with a backup", async () => {
  const email = "legacydata@example.com";
  const accessToken = "aat_" + crypto.randomBytes(12).toString("hex");
  const refreshToken = "art_" + crypto.randomBytes(12).toString("hex");
  const legacyDb = {
    users: {
      [email]: {
        id: "usr_old", email, verified: true,
        password_hash: "v1$scrypt$32768$8$1$" + Buffer.from("salt").toString("base64") + "$" + Buffer.from("hash").toString("base64"),
        plan: { status: "active", expires_at: Math.floor(Date.now() / 1000) + 86400, max_devices: 2, traffic_gb: 0 },
      },
    },
    sessions: {
      [accessToken]: {
        sessionId: "sess_old", userId: "usr_old", email, deviceId: "dev_old",
        accessToken, refreshToken, expiresAt: Date.now() + 86400 * 1000,
      },
      [refreshToken]: {
        sessionId: "sess_old", userId: "usr_old", email, deviceId: "dev_old",
        accessToken, refreshToken, expiresAt: Date.now() + 86400 * 1000,
      },
    },
    verify_codes: { "pending@example.com": { code: "123456", expiresAt: Date.now() + 60000 } },
  };
  fs.writeFileSync(DB_FILE, JSON.stringify(legacyDb, null, 2));

  initDataStore();

  // Sessions are re-keyed by digest, plaintext material is gone, and the
  // migration wrote a backup of the pre-migration file.
  const keys = Object.keys(cp.DB.sessions);
  assert.ok(keys.length >= 2);
  for (const key of keys) {
    assert.ok(/^[0-9a-f]{64}$/.test(key), "session map keys must be token digests");
    const session = cp.DB.sessions[key];
    assert.strictEqual(session.accessToken, undefined);
    assert.strictEqual(session.refreshToken, undefined);
  }
  const raw = fs.readFileSync(DB_FILE, "utf8");
  assert.ok(!raw.includes(accessToken) && !raw.includes(refreshToken),
    "plaintext tokens must not survive migration on disk");
  const backups = fs.readdirSync(tmpDir).filter((f) => f.includes(".backup-legacy-session-migration-"));
  assert.strictEqual(backups.length, 1, "exactly one migration backup must be written");

  // The client holding the legacy tokens can still authenticate afterwards.
  const me = await request("GET", "/v1/account", undefined, accessToken);
  assert.strictEqual(me.status, 200, "digest migration must preserve the ability to authenticate");
});

test("emails are masked in logs", () => {
  assert.strictEqual(cp.maskEmail("user@example.com"), "u***@e***.com");
  assert.strictEqual(cp.maskEmail("a@b.co"), "a***@b***.co");
  assert.notStrictEqual(cp.maskEmail("user@example.com"), "user@example.com");
});

test("connect sessions never leak into the login-session store", async () => {
  const email = "separation@example.com";
  const tokens = await registerAndLogin(email, "secretpass7", "dev_sep");
  activatePlan(email, { max_devices: 2 });
  const conn = await request("POST", "/v1/connect", { region_id: "us", device_id: "dev_sep" }, tokens.access_token);
  assert.strictEqual(conn.status, 200);
  assert.strictEqual(cp.DB.sessions[conn.body.session_id], undefined,
    "connect session ids must not be keys of the auth session store");
  assert.ok(cp.DB.sessions[cp.hashToken(tokens.access_token)], "auth sessions remain digest-keyed");
});

test("static node credentials are issued while per-user mode is opt-in", async () => {
  assert.equal(cp.PER_USER_CREDENTIALS, false);
  const email = `static-creds-${Date.now()}@test.aerovpn.dev`;
  const tokens = await registerAndLogin(email, "Str0ngPassw0rd!", "dev_static");
  activatePlan(email, { max_devices: 1 });
  const res = await request("POST", "/v1/connect", { region_id: "us", device_id: "dev_static" }, tokens.access_token);
  assert.equal(res.status, 200);
  // Static credentials must come through regardless of which protocol the
  // region's auto selection picked.
  if (res.body.protocol === "hysteria2") {
    assert.equal(res.body.node_spec.password, "hy2pass");
  } else {
    assert.equal(res.body.node_spec.uuid, "b831381d-6324-4d53-ad4f-8cda48b30811");
  }
});

test("per-session credential derivation is deterministic, unique per session/user, valid UUIDv5", () => {
  const a = cp.deriveSessionCredentials("user-1", { id: "sess-1", expiresAt: 1000 });
  const a2 = cp.deriveSessionCredentials("user-1", { id: "sess-1", expiresAt: 1000 });
  const b = cp.deriveSessionCredentials("user-1", { id: "sess-2", expiresAt: 1000 });
  const c = cp.deriveSessionCredentials("user-2", { id: "sess-1", expiresAt: 1000 });
  assert.deepEqual(a, a2);
  assert.notEqual(a.hy2Password, b.hy2Password);
  assert.notEqual(a.hy2Password, c.hy2Password);
  assert.notEqual(a.hy2ObfsPassword, b.hy2ObfsPassword);
  assert.notEqual(a.vlessUuid, b.vlessUuid);
  assert.match(a.vlessUuid, /^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
});
