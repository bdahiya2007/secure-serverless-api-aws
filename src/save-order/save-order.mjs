// Pure order-saving logic. The DynamoDB call is injected so this file has no
// dependencies and can be unit-tested with Node's built-in test runner.

const ID_PATTERN = /^[A-Za-z0-9._-]{1,128}$/;
const ALLOWED_FIELDS = new Set(["orderId", "itemId", "quantity", "price"]);

const response = (statusCode, body) => ({
  statusCode,
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify(body),
});

// API Gateway proxy events carry the order as a JSON string in `body`.
// Direct invocations (aws lambda invoke) pass the order object itself.
const isProxyEvent = (event) =>
  event !== null && typeof event === "object" && !Array.isArray(event) && "requestContext" in event;

// Returns { order } on success or { error } with a message that never echoes the input.
export function extractOrder(event) {
  if (!isProxyEvent(event)) return { order: event };

  if (typeof event.body !== "string" || event.body === "") {
    return { error: "Request body is required" };
  }

  const raw = event.isBase64Encoded ? Buffer.from(event.body, "base64").toString("utf8") : event.body;
  try {
    return { order: JSON.parse(raw) };
  } catch {
    return { error: "Request body must be valid JSON" };
  }
}

// Returns an array of error strings; empty means the order is valid.
export function validateOrder(order) {
  if (order === null || typeof order !== "object" || Array.isArray(order)) {
    return ["Request must be a JSON object"];
  }

  const errors = [];

  for (const field of Object.keys(order)) {
    if (!ALLOWED_FIELDS.has(field)) errors.push(`Unknown field: ${field}`);
  }

  for (const key of ["orderId", "itemId"]) {
    if (typeof order[key] !== "string" || !ID_PATTERN.test(order[key])) {
      errors.push(`${key} is required: 1-128 characters of letters, numbers, '.', '_' or '-'`);
    }
  }

  if (order.quantity !== undefined) {
    if (!Number.isInteger(order.quantity) || order.quantity < 1 || order.quantity > 10000) {
      errors.push("quantity must be an integer between 1 and 10000");
    }
  }

  if (order.price !== undefined) {
    if (typeof order.price !== "number" || !Number.isFinite(order.price) || order.price < 0) {
      errors.push("price must be a number greater than or equal to 0");
    }
  }

  return errors;
}

// putItem: async ({ TableName, Item, ConditionExpression }) => void
export function createHandler({ putItem, tableName, now = () => new Date() }) {
  return async function handler(event, context) {
    const { order, error } = extractOrder(event);
    if (error) {
      return response(400, { message: "Invalid order", errors: [error] });
    }

    const errors = validateOrder(order);
    if (errors.length > 0) {
      return response(400, { message: "Invalid order", errors });
    }

    const item = { createdAt: now().toISOString() };
    for (const field of ALLOWED_FIELDS) {
      if (order[field] !== undefined) item[field] = order[field];
    }

    try {
      await putItem({
        TableName: tableName,
        Item: item,
        // Never silently overwrite an existing orderId + itemId.
        ConditionExpression: "attribute_not_exists(orderId) AND attribute_not_exists(itemId)",
      });
    } catch (err) {
      if (err?.name === "ConditionalCheckFailedException") {
        return response(409, { message: "Order item already exists" });
      }
      // Log the error type and request id only: never order contents or raw error messages.
      console.error(JSON.stringify({
        message: "Failed to save order",
        errorName: err?.name,
        requestId: context?.awsRequestId,
      }));
      return response(500, { message: "Internal error" });
    }

    return response(201, { orderId: item.orderId, itemId: item.itemId, createdAt: item.createdAt });
  };
}
