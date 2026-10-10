// Chooses where reads go: DynamoDB directly (the default) or a DAX cluster (when DAX_ENDPOINT is set).
// Pure logic with the clients injected, so it can be unit-tested without AWS or the DAX packages.

// dynamoQuery: (params) => Promise, the normal DynamoDB path.
// loadDax: () => Promise<{ DaxDocument }>, imported only when DAX is configured, so the default package needs no DAX code.
export async function createQuery({ env, dynamoQuery, loadDax }) {
  const endpoint = env.DAX_ENDPOINT;
  if (!endpoint) {
    return { query: dynamoQuery, consistentRead: true, backend: "dynamodb" };
  }

  const { DaxDocument } = await loadDax();
  const dax = new DaxDocument({ endpoints: endpoint, region: env.AWS_REGION });
  return {
    query: (params) => dax.query(params),
    // DAX passes strongly consistent reads to DynamoDB without caching them, so a cached read must be eventually consistent.
    consistentRead: false,
    backend: "dax",
  };
}
