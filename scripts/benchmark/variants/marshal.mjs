// Converts the plain values this function writes into DynamoDB attribute values, so the
// function can use the low-level client and avoid loading @aws-sdk/lib-dynamodb.
export function toAttributeValue(value) {
  if (typeof value === "string") return { S: value };
  if (typeof value === "number" && Number.isFinite(value)) return { N: String(value) };
  throw new TypeError(`Unsupported attribute type: ${typeof value}`);
}

export function toAttributeMap(item) {
  return Object.fromEntries(Object.entries(item).map(([key, value]) => [key, toAttributeValue(value)]));
}
