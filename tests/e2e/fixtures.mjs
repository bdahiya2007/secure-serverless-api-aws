// Shared constants for the mocked tests and their server. Nothing here talks to AWS.
export const PORT = 8766;
export const FAKE = {
  api: "https://api.example.test",
  host: "auth.example.test",
  clientId: "testclient1234567890abcd",
};

export function config(overrides = {}) {
  return {
    apiBaseUrl: `${FAKE.api}/dev`,
    redirectUri: `http://localhost:${PORT}/`,
    cognito: { host: FAKE.host, clientId: FAKE.clientId, scopes: "openid email" },
    ...overrides,
  };
}
