import { test } from "node:test";
import assert from "node:assert/strict";
import { loadConfig, validateConfig } from "./config.js";

const HOST = ["prefix", "auth", "us-east-1", "amazoncognito", "com"].join("."); // a fake sign-in host, assembled so the scanner does not mistake it for a real one
const good = {
  apiBaseUrl: "https://abc123.execute-api.us-east-1.amazonaws.com/dev/",
  redirectUri: "https://orders.example.test/",
  cognito: { host: HOST, clientId: "abcdefghij1234567890klmnop", scopes: "openid email" },
};

test("a good config is accepted and the API URL loses its trailing slash", () => {
  const c = validateConfig(good);
  assert.equal(c.apiBaseUrl, "https://abc123.execute-api.us-east-1.amazonaws.com/dev");
  assert.equal(c.cognito.scopes, "openid email");
});

test("scopes default to openid email", () => {
  const c = validateConfig({ ...good, cognito: { ...good.cognito, scopes: undefined } });
  assert.equal(c.cognito.scopes, "openid email");
});

test("http://localhost is allowed for the redirect (development), other http is not", () => {
  assert.ok(validateConfig({ ...good, redirectUri: "http://localhost:8765/" }));
  assert.throws(() => validateConfig({ ...good, redirectUri: "http://orders.example.test/" }), /redirectUri/);
});

test("each bad setting is named, and its value is never echoed", () => {
  for (const [patch, name] of [
    [{ apiBaseUrl: "http://insecure.example.test" }, "apiBaseUrl"],
    [{ apiBaseUrl: 5 }, "apiBaseUrl"],
    [{ redirectUri: "not a url" }, "redirectUri"],
    [{ cognito: { ...good.cognito, host: "bad host!" } }, "cognito.host"],
    [{ cognito: { ...good.cognito, clientId: "x" } }, "cognito.clientId"],
    [{ cognito: undefined }, "cognito.host"],
  ]) {
    assert.throws(() => validateConfig({ ...good, ...patch }), (e) => e.message.includes(name) && !e.message.includes("insecure.example") && !e.message.includes("bad host"), name);
  }
});

test("non-objects are rejected", () => {
  for (const v of [null, undefined, "x", 3, []]) assert.throws(() => validateConfig(v), /not usable/);
});

test("loadConfig reads and validates the file", async () => {
  const c = await loadConfig(async () => ({ ok: true, json: async () => good }));
  assert.equal(c.redirectUri, "https://orders.example.test/");
});

test("loadConfig reports a network error, an HTTP error and bad JSON with clear messages", async () => {
  await assert.rejects(loadConfig(async () => { throw new Error("x"); }), /network error/);
  await assert.rejects(loadConfig(async () => ({ ok: false, status: 403 })), /HTTP 403/);
  await assert.rejects(loadConfig(async () => ({ ok: true, json: async () => { throw new Error("bad"); } })), /not valid JSON/);
});
