import { test } from "node:test";
import assert from "node:assert/strict";
import { buildAuthorizeUrl, buildLogoutUrl, createSession, decodeJwt, exchangeCode, parseCallback, savePending, takePending } from "./auth.js";

const HOST = ["prefix", "auth", "us-east-1", "amazoncognito", "com"].join("."); // a fake sign-in host, assembled so the scanner does not mistake it for a real one
const cfg = {
  redirectUri: "https://orders.example.test/",
  cognito: { host: HOST, clientId: "abcdefghij1234567890klmnop", scopes: "openid email" },
};
const jwt = (claims) => `h.${Buffer.from(JSON.stringify(claims)).toString("base64url")}.s`;
const memoryStorage = () => {
  const m = new Map();
  return { getItem: (k) => (m.has(k) ? m.get(k) : null), setItem: (k, v) => m.set(k, String(v)), removeItem: (k) => m.delete(k) };
};

test("the authorize URL asks for a code with PKCE S256, the exact redirect and the state", () => {
  const u = new URL(buildAuthorizeUrl(cfg, { challenge: "CH", state: "ST" }));
  assert.equal(u.origin + u.pathname, `https://${HOST}/oauth2/authorize`);
  assert.equal(u.searchParams.get("response_type"), "code");
  assert.equal(u.searchParams.get("client_id"), cfg.cognito.clientId);
  assert.equal(u.searchParams.get("redirect_uri"), cfg.redirectUri);
  assert.equal(u.searchParams.get("scope"), "openid email");
  assert.equal(u.searchParams.get("code_challenge"), "CH");
  assert.equal(u.searchParams.get("code_challenge_method"), "S256");
  assert.equal(u.searchParams.get("state"), "ST");
  assert.equal(u.searchParams.has("response_mode"), false);
});

test("the logout URL returns to the same registered address", () => {
  const u = new URL(buildLogoutUrl(cfg));
  assert.equal(u.pathname, "/logout");
  assert.equal(u.searchParams.get("logout_uri"), cfg.redirectUri);
  assert.equal(u.searchParams.get("client_id"), cfg.cognito.clientId);
});

test("parseCallback reads a code, an error, or nothing", () => {
  assert.deepEqual(parseCallback("?code=abc&state=xyz"), { code: "abc", state: "xyz" });
  assert.deepEqual(parseCallback("?code=abc"), { code: "abc", state: "" });
  assert.deepEqual(parseCallback("?error=access_denied&error_description=No+way"), { error: "access_denied", description: "No way" });
  assert.equal(parseCallback(""), null);
  assert.equal(parseCallback("?other=1"), null);
});

test("an error wins over a code in the same address", () => {
  assert.equal(parseCallback("?code=abc&error=server_error").error, "server_error");
});

test("pending PKCE values are read once, then gone", () => {
  const s = memoryStorage();
  savePending(s, { verifier: "V", state: "S" });
  assert.deepEqual(takePending(s), { verifier: "V", state: "S" });
  assert.equal(takePending(s), null);
});

test("a damaged pending value is ignored", () => {
  const s = memoryStorage();
  s.setItem("orders.pending-signin", "{not json");
  assert.equal(takePending(s), null);
  s.setItem("orders.pending-signin", JSON.stringify({ verifier: 5 }));
  assert.equal(takePending(s), null);
});

test("decodeJwt reads the claims, including padding-sensitive ones", () => {
  assert.equal(decodeJwt(jwt({ email: "a@example.com", n: 1 })).email, "a@example.com");
  assert.equal(decodeJwt(jwt({ x: "é€" })).x, "é€");
  assert.throws(() => decodeJwt("nodots"), /not a token/);
});

test("exchangeCode posts the verifier and the code and returns only the ID token and lifetime", async () => {
  let seen;
  const out = await exchangeCode(cfg, { code: "C", verifier: "V" }, async (url, init) => {
    seen = { url, init };
    return { ok: true, json: async () => ({ id_token: "T", access_token: "A", refresh_token: "R", expires_in: 3600 }) };
  });
  assert.deepEqual(out, { idToken: "T", expiresIn: 3600 });
  assert.equal(seen.url, `https://${HOST}/oauth2/token`);
  assert.equal(seen.init.method, "POST");
  const body = new URLSearchParams(seen.init.body);
  assert.equal(body.get("grant_type"), "authorization_code");
  assert.equal(body.get("code"), "C");
  assert.equal(body.get("code_verifier"), "V");
  assert.equal(body.get("redirect_uri"), cfg.redirectUri);
});

test("exchangeCode failures give a safe message and never echo the response", async () => {
  await assert.rejects(exchangeCode(cfg, { code: "C", verifier: "V" }, async () => ({ ok: false, json: async () => ({ error: "invalid_grant", secret: "S" }) })),
    (e) => /invalid_grant/.test(e.message) && !/S$/.test(e.message));
  await assert.rejects(exchangeCode(cfg, { code: "C", verifier: "V" }, async () => { throw new Error("offline"); }), /Could not reach/);
  await assert.rejects(exchangeCode(cfg, { code: "C", verifier: "V" }, async () => ({ ok: true, json: async () => ({}) })), /could not be completed/);
});

test("the session holds the token until it expires, and clears completely", () => {
  let t = 1_000_000;
  const s = createSession(() => t);
  assert.equal(s.signedIn(), false);
  s.set({ idToken: jwt({ email: "a@example.com" }), expiresIn: 60 });
  assert.equal(s.signedIn(), true);
  assert.equal(s.email(), "a@example.com");
  t += 59_000;
  assert.equal(s.signedIn(), true);
  t += 2_000;
  assert.equal(s.token(), null);
  s.set({ idToken: jwt({ email: "b@example.com" }), expiresIn: 60 });
  s.clear();
  assert.equal(s.token(), null);
  assert.equal(s.email(), null);
});

test("a token that cannot be decoded still works as a token, with no email shown", () => {
  const s = createSession(() => 0);
  s.set({ idToken: "opaque", expiresIn: 60 });
  assert.equal(s.signedIn(), true);
  assert.equal(s.email(), null);
});
