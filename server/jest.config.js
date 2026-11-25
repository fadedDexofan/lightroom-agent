export default {
  preset: 'ts-jest/presets/default-esm',
  testEnvironment: 'node',
  extensionsToTreatAsEsm: ['.ts'],
  moduleNameMapper: {
    '^(\\.{1,2}/.*)\\.js$': '$1',
  },
  transform: {
    '^.+\\.tsx?$': [
      'ts-jest',
      {
        useESM: true,
        tsconfig: { module: 'CommonJS', verbatimModuleSyntax: false },
      },
    ],
  },
  testMatch: ['**/tests/**/*.test.ts'],
  collectCoverageFrom: ['src/**/*.ts'],
  coverageProvider: 'v8',
  // Ratchet: raise these as coverage climbs. `index.ts` is the bin entrypoint
  // (socket + stdio wiring) and is not unit-tested yet — issue #97 step 4
  // tracks covering it before its threshold is lifted off the floor. A path
  // entry is subtracted from `global`, so `global` covers every other file.
  coverageThreshold: {
    global: {
      statements: 95,
      branches: 89,
      functions: 90,
      lines: 95,
    },
    './src/index.ts': {
      statements: 0,
      branches: 0,
      functions: 0,
      lines: 0,
    },
  },
};
