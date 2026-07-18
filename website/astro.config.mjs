// @ts-check
import { defineConfig } from 'astro/config';

// Static site. Deploys to Cloudflare Pages as a plain dist/ (build command
// `astro build`, output directory `dist`). No SSR needed.
export default defineConfig({
  site: 'https://roundtable.rahulkrishna.dev',
});
