// Sign-in with Cognito's hosted pages: the authorization code flow with PKCE. The page never sees the password.
// Tokens live only in memory (see createSession); only the one-time PKCE values survive the redirect, in sessionStorage.

const PENDING_KEY = "orders.pending-signin";

export function buildAuthorizeUrl(cfg, { challenge, state }) {
  const q = new URLSearchParams({
    response_type: "code",
    client_id: cfg.cognito.clientId,
    redirect_uri: cfg.redirectUri,
    scope: cfg.cognito.scopes,
    code_challenge: challenge,
    code_challenge_method: "S256",
    state,
  });
  return `https://${cfg.cognito.host}/oauth2/authorize?${q}`;
}

export function buildLogoutUrl(cfg) {
  const q = new URLSearchParams({ client_id: cfg.cognito.clientId, logout_uri: cfg.redirectUri });
  return `https://${cfg.cognito.host}/logout?${q}`;
}

// What Cognito put in the address after the redirect: a code and the state, or an error. Null when this is not a callback.
export function parseCallback(search) {
  const q = new URLSearchParams(search);
  if (q.has("error")) return { error: q.get("error"), description: q.get("error_description") || "" };
  if (q.has("code")) return { code: q.get("code"), state: q.get("state") || "" };
  return null;
}

export function savePending(storage, { verifier, state }) {
  storage.setItem(PENDING_KEY, JSON.stringify({ verifier, state }));
}

// Read and delete: a verifier is used once.
export function takePending(storage) {
  const raw = storage.getItem(PENDING_KEY);
  storage.removeItem(PENDING_KEY);
  if (raw === null) return null;
  try {
    const p = JSON.parse(raw);
    return typeof p.verifier === "string" && typeof p.state === "string" ? p : null;
  } catch {
    return null;
  }
}

// base64url JSON payload of a token. For display only: the API validates the token, never this page.
export function decodeJwt(token) {
  const part = String(token).split(".")[1];
  if (!part) throw new Error("not a token");
  const padded = part.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - (part.length % 4)) % 4);
  const json = new TextDecoder().decode(Uint8Array.from(atob(padded), (c) => c.charCodeAt(0)));
  return JSON.parse(json);
}

export async function exchangeCode(cfg, { code, verifier }, fetchFn = globalThis.fetch) {
  const body = new URLSearchParams({
    grant_type: "authorization_code",
    client_id: cfg.cognito.clientId,
    code,
    redirect_uri: cfg.redirectUri,
    code_verifier: verifier,
  });
  let response;
  try {
    response = await fetchFn(`https://${cfg.cognito.host}/oauth2/token`, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body,
    });
  } catch {
    throw new Error("Could not reach the sign-in service.");
  }
  let data = {};
  try {
    data = await response.json();
  } catch {
    // keep {}
  }
  if (!response.ok || typeof data.id_token !== "string") {
    // Cognito's error code (for example invalid_grant) is safe to show; nothing else from the response is.
    throw new Error(`Sign-in could not be completed${typeof data.error === "string" ? ` (${data.error})` : ""}.`);
  }
  return { idToken: data.id_token, expiresIn: Number(data.expires_in) || 3600 };
}

// The session: the ID token and when it ends, in memory only (a page reload signs out, and the hosted pages sign straight back in).
export function createSession(now = () => Date.now()) {
  let idToken = null;
  let expiresAt = 0;
  let claims = null;
  return {
    set({ idToken: token, expiresIn }) {
      idToken = token;
      expiresAt = now() + expiresIn * 1000;
      try {
        claims = decodeJwt(token);
      } catch {
        claims = null;
      }
    },
    clear() {
      idToken = null;
      expiresAt = 0;
      claims = null;
    },
    token() {
      return idToken !== null && now() < expiresAt ? idToken : null;
    },
    signedIn() {
      return this.token() !== null;
    },
    email() {
      return typeof claims?.email === "string" ? claims.email : null;
    },
    expiresAt() {
      return expiresAt;
    },
  };
}
