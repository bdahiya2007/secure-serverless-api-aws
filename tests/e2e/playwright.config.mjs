import { defineConfig } from "@playwright/test";

const live = process.env.E2E_LIVE === "1";

export default defineConfig({
  testDir: ".",
  testMatch: ["mocked.spec.mjs", "live.spec.mjs"],
  fullyParallel: false,
  workers: 1,
  retries: 0,
  timeout: 30_000,
  reporter: [["list"]],
  use: { headless: true, actionTimeout: 10_000, trace: "retain-on-failure" },
  projects: [
    { name: "mocked", testMatch: "mocked.spec.mjs", use: { baseURL: "http://localhost:8766" } },
    // Real sign-in and API: only with E2E_LIVE=1 (it needs AWS credentials and creates a temporary user).
    ...(live ? [{ name: "live", testMatch: "live.spec.mjs", timeout: 90_000, use: { baseURL: "http://localhost:8765" } }] : []),
  ],
  webServer: [
    { command: "node static-server.mjs", url: "http://localhost:8766/", reuseExistingServer: false, timeout: 20_000 },
    ...(live ? [{ command: "python3 -u ../../scripts/dev-frontend.py", url: "http://localhost:8765/", reuseExistingServer: true, timeout: 90_000 }] : []),
  ],
});
