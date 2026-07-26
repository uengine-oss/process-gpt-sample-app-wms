import { defineConfig, devices } from '@playwright/test'

const baseURL = process.env.BASE_URL || 'http://localhost:5273'
const useManagedWebServer = !process.env.BASE_URL

export default defineConfig({
  testDir: './playwright/e2e',
  timeout: 90_000,
  outputDir: './playwright/test-results',
  preserveOutput: 'always',
  fullyParallel: false,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 1 : 0,
  workers: 1,
  reporter: [
    ['html', { outputFolder: './playwright/playwright-report' }],
    ['list'],
  ],
  use: {
    baseURL,
    trace: 'off',
    video: 'off',
    screenshot: 'only-on-failure',
  },
  projects: [
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'] },
    },
  ],
  ...(useManagedWebServer
    ? {
        webServer: {
          command: 'npm run dev',
          port: 5273,
          reuseExistingServer: true,
          timeout: 60_000,
        },
      }
    : {}),
})
