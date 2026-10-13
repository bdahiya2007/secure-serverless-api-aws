import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, PutCommand } from "@aws-sdk/lib-dynamodb";
import { createHandler } from "./save-order.mjs";
import { parseAllowedOrigins } from "./cors.mjs";

const tableName = process.env.TABLE_NAME;
if (!tableName) throw new Error("TABLE_NAME environment variable is required");

const client = DynamoDBDocumentClient.from(new DynamoDBClient({}));

export const handler = createHandler({
  tableName,
  // Origins of the browser front end (comma-separated ALLOWED_ORIGINS). Empty by default: no CORS headers.
  allowedOrigins: parseAllowedOrigins(process.env.ALLOWED_ORIGINS),
  putItem: (params) => client.send(new PutCommand(params)),
});
