module.exports = [
  {
    ignores: [
      "node_modules/**",
      ".npm-cache/**",
      ".wwebjs_auth/**",
      ".wwebjs_cache/**",
      "logs/**",
      "queues/**"
    ]
  },
  {
    files: ["*.js", "lib/**/*.js", "tests/**/*.js"],
    languageOptions: {
      ecmaVersion: 2022,
      sourceType: "commonjs",
      globals: {
        Buffer: "readonly",
        __dirname: "readonly",
        clearTimeout: "readonly",
        console: "readonly",
        exports: "writable",
        module: "readonly",
        process: "readonly",
        require: "readonly",
        setImmediate: "readonly",
        setTimeout: "readonly"
      }
    },
    rules: {
      "eqeqeq": ["error", "smart"],
      "no-constant-condition": "warn",
      "no-redeclare": "error",
      "no-undef": "error",
      "no-unreachable": "error",
      "no-unused-vars": ["warn", {
        "argsIgnorePattern": "^_",
        "caughtErrorsIgnorePattern": "^_",
        "varsIgnorePattern": "^_"
      }]
    }
  }
];
