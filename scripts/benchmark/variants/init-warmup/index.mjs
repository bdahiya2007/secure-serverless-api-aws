import { DynamoDBClient, PutItemCommand } from "@aws-sdk/client-dynamodb";
import { createHandler } from "./save-order.mjs";
import { toAttributeMap } from "./marshal.mjs";

const tableName = process.env.TABLE_NAME;
if (!tableName) throw new Error("TABLE_NAME environment variable is required");

// Created once per execution environment (init phase), not per request. Short timeouts make a
// hung connection fail fast instead of running into the 10 s function timeout.
const client = new DynamoDBClient({
  requestHandler: { connectionTimeout: 1000, requestTimeout: 3000 },
});

// Lambda gives the init phase extra CPU, so resolve credentials and region now instead of during
// the first request. Failures are ignored here and surface normally on the first real call.
await Promise.allSettled([client.config.credentials(), client.config.region()]);

export const handler = createHandler({
  tableName,
  putItem: ({ TableName, Item, ConditionExpression }) =>
    client.send(new PutItemCommand({ TableName, Item: toAttributeMap(Item), ConditionExpression })),
});
