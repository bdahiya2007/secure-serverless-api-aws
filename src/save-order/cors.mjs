// CORS for the browser front end. Pure logic with no dependencies. API Gateway adds no CORS headers to a Lambda proxy
// response, so the function does: it echoes the request's Origin only when that exact origin is on the allow-list, never "*".
// With no allowed origins configured (the default) it adds nothing, so the API behaves exactly as before.
// NOTE: src/get-order/cors.mjs is an identical copy (the two functions are packaged separately); keep them in step.

export function parseAllowedOrigins(raw) {
  return String(raw ?? "")
    .split(",")
    .map((o) => o.trim())
    .filter(Boolean);
}

// HTTP header names are case-insensitive, and API Gateway keeps the case the client sent.
function headerValue(headers, name) {
  if (headers === null || typeof headers !== "object") return undefined;
  const key = Object.keys(headers).find((k) => k.toLowerCase() === name);
  return key === undefined ? undefined : headers[key];
}

export function corsHeaders(event, allowedOrigins) {
  if (!Array.isArray(allowedOrigins) || allowedOrigins.length === 0) return {};
  const headers = { Vary: "Origin" }; // the answer depends on the Origin header, so caches must key on it
  const origin = headerValue(event?.headers, "origin");
  if (typeof origin === "string" && allowedOrigins.includes(origin)) {
    headers["Access-Control-Allow-Origin"] = origin;
  }
  return headers;
}
