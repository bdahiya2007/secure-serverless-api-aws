import { test } from "node:test";
import assert from "node:assert/strict";
import { base64url, challengeFor, createPkce, randomString } from "./pkce.js";

test("the S256 challenge matches the example in RFC 7636", async () => {
  assert.equal(await challengeFor("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM");
});

test("base64url has no padding and no + or /", () => {
  assert.equal(base64url(new Uint8Array([251, 255, 254])), "-__-");
  assert.equal(base64url(new Uint8Array([1])), "AQ");
  assert.ok(!/[+/=]/.test(base64url(crypto.getRandomValues(new Uint8Array(100)))));
});

test("random strings are unique, URL safe and the right length", () => {
  const a = randomString(32);
  const b = randomString(32);
  assert.notEqual(a, b);
  assert.match(a, /^[A-Za-z0-9_-]{43}$/);
});

test("a PKCE set has a verifier of at least 43 characters, its challenge and a separate state", async () => {
  const { verifier, challenge, state } = await createPkce();
  assert.ok(verifier.length >= 43 && verifier.length <= 128);
  assert.equal(challenge, await challengeFor(verifier));
  assert.notEqual(state, verifier);
  assert.match(state, /^[A-Za-z0-9_-]+$/);
});

test("two PKCE sets differ", async () => {
  const [a, b] = [await createPkce(), await createPkce()];
  assert.notEqual(a.verifier, b.verifier);
  assert.notEqual(a.state, b.state);
});
