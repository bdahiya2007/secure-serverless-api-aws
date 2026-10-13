// Public settings the page reads at start-up from /config.json (generated from the deployed stack; no secrets).

const HOST = /^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$/i;
const CLIENT_ID = /^[A-Za-z0-9]{10,64}$/;

function isHttpsUrl(value) {
  try {
    return new URL(value).protocol === "https:";
  } catch {
    return false;
  }
}

// Returns a clean copy, or throws an Error that says WHICH setting is wrong (never its value).
export function validateConfig(raw) {
  const problems = [];
  const c = raw !== null && typeof raw === "object" ? raw : {};
  const cognito = c.cognito !== null && typeof c.cognito === "object" ? c.cognito : {};

  if (typeof c.apiBaseUrl !== "string" || !isHttpsUrl(c.apiBaseUrl)) problems.push("apiBaseUrl must be an https URL");
  if (typeof c.redirectUri !== "string" || !(isHttpsUrl(c.redirectUri) || /^http:\/\/localhost(:\d+)?\//.test(c.redirectUri))) {
    problems.push("redirectUri must be an https URL (or http://localhost for development)");
  }
  if (typeof cognito.host !== "string" || !HOST.test(cognito.host)) problems.push("cognito.host must be a host name");
  if (typeof cognito.clientId !== "string" || !CLIENT_ID.test(cognito.clientId)) problems.push("cognito.clientId must be a client ID");
  if (cognito.scopes !== undefined && typeof cognito.scopes !== "string") problems.push("cognito.scopes must be a string");

  if (problems.length > 0) throw new Error(`config.json is not usable: ${problems.join("; ")}`);

  return {
    apiBaseUrl: c.apiBaseUrl.replace(/\/+$/, ""),
    redirectUri: c.redirectUri,
    cognito: { host: cognito.host, clientId: cognito.clientId, scopes: cognito.scopes || "openid email" },
  };
}

export async function loadConfig(fetchFn = globalThis.fetch, url = "config.json") {
  let response;
  try {
    response = await fetchFn(url, { cache: "no-store" });
  } catch {
    throw new Error("config.json could not be loaded (network error)");
  }
  if (!response.ok) throw new Error(`config.json could not be loaded (HTTP ${response.status})`);
  let raw;
  try {
    raw = await response.json();
  } catch {
    throw new Error("config.json is not valid JSON");
  }
  return validateConfig(raw);
}
