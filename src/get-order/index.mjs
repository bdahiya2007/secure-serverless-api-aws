import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, QueryCommand } from "@aws-sdk/lib-dynamodb";
import { createHandler } from "./get-order.mjs";

const tableName = process.env.TABLE_NAME;
if (!tableName) throw new Error("TABLE_NAME environment variable is required");

// Created once per execution environment (init phase), not per request.
const client = DynamoDBDocumentClient.from(new DynamoDBClient({}));

export const handler = createHandler({
  tableName,
  query: (params) => client.send(new QueryCommand(params)),
});
