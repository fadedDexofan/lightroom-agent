import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    include: ['tests/**/*.test.ts'],
    coverage: {
      provider: 'v8',
      include: ['src/**/*.ts'],
      // Ratchet: raise these as coverage climbs. `index.ts` is the bin entrypoint
      // (socket + stdio wiring) and is not unit-tested yet — issue #97 step 4
      // tracks covering it before its threshold is lifted off the floor.
      thresholds: {
        '!(src/index.ts)': {
          statements: 95,
          branches: 89,
          functions: 90,
          lines: 95,
        },
        'src/index.ts': {
          statements: 0,
          branches: 0,
          functions: 0,
          lines: 0,
        },
      },
    },
  },
});
