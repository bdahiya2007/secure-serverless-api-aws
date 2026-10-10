import { DynamoDBClient, PutItemCommand } from "@aws-sdk/client-dynamodb";
import { createHandler } from "./save-order.mjs";
import { toAttributeMap } from "./marshal.mjs";

const tableName = process.env.TABLE_NAME;
if (!tableName) throw new Error("TABLE_NAME environment variable is required");

// Created once per execution environment (init phase), not per request.
const client = new DynamoDBClient({});

export const handler = createHandler({
  tableName,
  putItem: ({ TableName, Item, ConditionExpression }) =>
    client.send(new PutItemCommand({ TableName, Item: toAttributeMap(Item), ConditionExpression })),
});
