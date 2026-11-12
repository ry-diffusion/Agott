import { cloudflareTest } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

export default defineConfig({
	plugins: [
		cloudflareTest({
			wrangler: { configPath: "./wrangler.jsonc" },
			miniflare: {
				// Made-up tokens for the tests only.
				bindings: {
					AGOTT_TOKENS: "test-token-alice-0123456789abcdefghij,\ntest-token-bruno-0123456789abcdefghij, short",
				},
			},
		}),
	],
});
