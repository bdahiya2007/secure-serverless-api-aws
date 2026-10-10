// Pure order-reading logic. The DynamoDB call is injected so this file has no dependencies and can be
// unit-tested with Node's built-in test runner.

const ID_PATTERN = /^[A-Za-z0-9._-]{1,128}$/;
const MAX_ITEMS = 100;

const response = (statusCode, body) => ({
  statusCode,
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify(body),
});

// Returns { orderId } on success or { error } (a message that never echoes the input).
export function parseOrderId(event) {
  const raw = event?.pathParameters?.orderId;
  if (typeof raw !== "string") return { error: "orderId is required" };
  if (!ID_PATTERN.test(raw)) {
    return { error: "orderId must be 1-128 characters of letters, numbers, '.', '_' or '-'" };
  }
  return { orderId: raw };
}

// Same item shape as the direct DynamoDB integration: missing optional attributes become null.
export function toItem(item) {
  return {
    itemId: item.itemId,
    quantity: item.quantity ?? null,
    price: item.price ?? null,
    createdAt: item.createdAt,
  };
}

// query: async (params) => ({ Items, LastEvaluatedKey })
// consistentRead: strongly consistent reads see the latest write but cannot be cached by DAX, which passes them through.
export function createHandler({ query, tableName, consistentRead = true }) {
  return async function handler(event, context) {
    const { orderId, error } = parseOrderId(event);
    if (error) return response(400, { message: "Invalid order id", errors: [error] });

    let result;
    try {
      result = await query({
        TableName: tableName,
        // The id is a value, never part of the expression.
        KeyConditionExpression: "orderId = :orderId",
        ExpressionAttributeValues: { ":orderId": orderId },
        ConsistentRead: consistentRead, // true: a client reads back what it just wrote
        Limit: MAX_ITEMS,
      });
    } catch (err) {
      // Log the error type and request id only: never the id or raw error messages.
      console.error(JSON.stringify({
        message: "Failed to read order",
        errorName: err?.name,
        requestId: context?.awsRequestId,
      }));
      return response(500, { message: "Internal error" });
    }

    const items = result.Items ?? [];
    if (items.length === 0) return response(404, { message: "Order not found" });

    return response(200, {
      orderId,
      itemCount: items.length,
      items: items.map(toItem),
      // Unlike the VTL template, code can tell the client that the 100-item cap cut the list off.
      truncated: result.LastEvaluatedKey !== undefined,
    });
  };
}
