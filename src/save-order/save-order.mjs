// Pure order-saving logic. The DynamoDB call is injected so this file has no
// dependencies and can be unit-tested with Node's built-in test runner.

const ID_PATTERN = /^[A-Za-z0-9._-]{1,128}$/;
const ALLOWED_FIELDS = new Set(["orderId", "itemId", "quantity", "price"]);

const response = (statusCode, body) => ({
  statusCode,
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify(body),
});

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
    const errors = validateOrder(event);
    if (errors.length > 0) {
      return response(400, { message: "Invalid order", errors });
    }

    const item = { createdAt: now().toISOString() };
    for (const field of ALLOWED_FIELDS) {
      if (event[field] !== undefined) item[field] = event[field];
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
