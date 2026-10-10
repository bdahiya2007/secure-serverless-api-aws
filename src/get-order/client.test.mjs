import { test } from "node:test";
import assert from "node:assert/strict";
import { createQuery } from "./client.mjs";

const dynamoQuery = async () => ({ Items: [], source: "dynamodb" });

test("without DAX_ENDPOINT it uses DynamoDB, strongly consistent, and never loads the DAX package", async () => {
  let loaded = false;
  const r = await createQuery({ env: {}, dynamoQuery, loadDax: async () => { loaded = true; } });
  assert.equal(r.backend, "dynamodb");
  assert.equal(r.consistentRead, true);
  assert.equal(r.query, dynamoQuery);
  assert.equal(loaded, false);
});

test("an empty DAX_ENDPOINT counts as not set", async () => {
  const r = await createQuery({ env: { DAX_ENDPOINT: "" }, dynamoQuery, loadDax: async () => { throw new Error("must not load"); } });
  assert.equal(r.backend, "dynamodb");
});

test("with DAX_ENDPOINT it builds a DAX client for that endpoint and region, eventually consistent", async () => {
  const seen = [];
  class FakeDaxDocument {
    constructor(config) { seen.push(config); }
    async query(params) { return { Items: [{ via: "dax", params }] }; }
  }
  const r = await createQuery({
    env: { DAX_ENDPOINT: "daxs://c.example.dax-clusters.us-east-1.amazonaws.com", AWS_REGION: "us-east-1" },
    dynamoQuery,
    loadDax: async () => ({ DaxDocument: FakeDaxDocument }),
  });
  assert.equal(r.backend, "dax");
  assert.equal(r.consistentRead, false, "DAX cannot cache strongly consistent reads");
  assert.deepEqual(seen, [{ endpoints: "daxs://c.example.dax-clusters.us-east-1.amazonaws.com", region: "us-east-1" }]);
  const out = await r.query({ TableName: "Orders" });
  assert.equal(out.Items[0].via, "dax");
});

test("a failure to load the DAX package is not swallowed", async () => {
  await assert.rejects(
    createQuery({ env: { DAX_ENDPOINT: "daxs://x" }, dynamoQuery, loadDax: async () => { throw new Error("Cannot find package"); } }),
    /Cannot find package/,
  );
});
