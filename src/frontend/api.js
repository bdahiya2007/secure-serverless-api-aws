// Calls to the orders API. Every call returns a plain result instead of throwing:
//   { ok: true,  status, data, ms }                                   success (ms is the time the browser measured)
//   { ok: false, kind, status, message, details, ms }                 a failure with a message that is safe to show
// kind is one of: signin, invalid, unauthorized, forbidden, not_found, conflict, throttled, server, network, unexpected.
// The ID token goes in the Authorization header as-is (this API expects no "Bearer" prefix), is never put in a URL, and never
// appears in a message.

const MESSAGES = {
  invalid: "The request was rejected. Check the details below and try again.",
  unauthorized: "Your session has ended. Please sign in again.",
  forbidden: "The API refused this request.",
  not_found: "No such order.",
  conflict: "That order item already exists. An order item can be saved only once.",
  throttled: "Too many requests right now. Wait a few seconds and try again.",
  server: "Something went wrong on the server. Try again in a moment.",
  network: "Could not reach the API. Check your connection (a browser also reports a blocked cross-origin call this way).",
  unexpected: "The API answered in a way this page did not expect.",
  signin: "Please sign in first.",
};

const KIND_BY_STATUS = { 400: "invalid", 401: "unauthorized", 403: "forbidden", 404: "not_found", 409: "conflict", 429: "throttled" };

export function kindForStatus(status) {
  if (KIND_BY_STATUS[status]) return KIND_BY_STATUS[status];
  return status >= 500 ? "server" : "unexpected";
}

// Up to five short strings from the API's `errors` array: validation messages that never echo the input.
function detailsFrom(body) {
  if (!Array.isArray(body?.errors)) return [];
  return body.errors.filter((e) => typeof e === "string").slice(0, 5).map((e) => e.slice(0, 200));
}

export function failure(kind, status, body, ms) {
  return { ok: false, kind, status, message: MESSAGES[kind] ?? MESSAGES.unexpected, details: detailsFrom(body), ms };
}

export function createApi({ baseUrl, getToken, onUnauthorized = () => {}, fetchFn = globalThis.fetch, clock = () => performance.now() }) {
  async function request(method, path, payload) {
    const token = getToken();
    if (!token) return failure("signin", 0, null, 0);

    const headers = { Authorization: token };
    const init = { method, headers };
    if (payload !== undefined) {
      headers["Content-Type"] = "application/json";
      init.body = JSON.stringify(payload);
    }

    const started = clock();
    let response;
    try {
      response = await fetchFn(`${baseUrl}${path}`, init);
    } catch {
      return failure("network", 0, null, clock() - started);
    }
    const ms = clock() - started;

    let body = null;
    try {
      body = await response.json();
    } catch {
      // not JSON (or empty): fine
    }

    if (response.ok) return { ok: true, status: response.status, data: body, ms };

    const kind = kindForStatus(response.status);
    if (kind === "unauthorized") onUnauthorized();
    return failure(kind, response.status, body, ms);
  }

  const enc = encodeURIComponent;
  return {
    createOrder: (order) => request("POST", "/orders", order),
    getOrderDirect: (orderId) => request("GET", `/orders/${enc(orderId)}`),
    getOrderViaLambda: (orderId) => request("GET", `/orders-via-lambda/${enc(orderId)}`),
  };
}
