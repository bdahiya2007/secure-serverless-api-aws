import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, PutCommand } from "@aws-sdk/lib-dynamodb";
import { createHandler } from "./save-order.mjs";

const tableName = process.env.TABLE_NAME;
if (!tableName) throw new Error("TABLE_NAME environment variable is required");

const client = DynamoDBDocumentClient.from(new DynamoDBClient({}));

export const handler = createHandler({
  tableName,
  putItem: (params) => client.send(new PutCommand(params)),
});
