import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, QueryCommand } from "@aws-sdk/lib-dynamodb";
import { createHandler } from "./get-order.mjs";
import { createQuery } from "./client.mjs";

const tableName = process.env.TABLE_NAME;
if (!tableName) throw new Error("TABLE_NAME environment variable is required");

// Created once per execution environment (init phase), not per request.
const documentClient = DynamoDBDocumentClient.from(new DynamoDBClient({}));

const { query, consistentRead, backend } = await createQuery({
  env: process.env,
  dynamoQuery: (params) => documentClient.send(new QueryCommand(params)),
  // Only imported when DAX_ENDPOINT is set. The package is built with ./scripts/build-dax-package.sh in that case.
  loadDax: () => import("@amazon-dax-sdk/lib-dax"),
});

console.log(JSON.stringify({ message: "read backend selected", backend, consistentRead }));

export const handler = createHandler({ tableName, query, consistentRead });
