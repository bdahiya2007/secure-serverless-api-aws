// PKCE (RFC 7636) with the Web Crypto API, available in every current browser and in Node.
// The verifier is a random secret the page keeps for the round trip; only its SHA-256 hash (the challenge) is sent in the
// sign-in URL, so an authorization code intercepted in the redirect is useless without the verifier.

export function base64url(bytes) {
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function randomString(byteLength = 32, cryptoApi = globalThis.crypto) {
  const bytes = new Uint8Array(byteLength);
  cryptoApi.getRandomValues(bytes);
  return base64url(bytes);
}

export async function challengeFor(verifier, cryptoApi = globalThis.crypto) {
  const digest = await cryptoApi.subtle.digest("SHA-256", new TextEncoder().encode(verifier));
  return base64url(new Uint8Array(digest));
}

// A fresh verifier (43 or more characters, as the RFC requires), its challenge, and a random state value for this attempt.
export async function createPkce(cryptoApi = globalThis.crypto) {
  const verifier = randomString(48, cryptoApi); // 64 characters
  return { verifier, challenge: await challengeFor(verifier, cryptoApi), state: randomString(16, cryptoApi) };
}
