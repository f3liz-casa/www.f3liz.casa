# f3lizcasa-web

The web behind **f3liz.casa** — a small monorepo of the sites and pages that
live under that domain. Each app is self-contained and deploys on its own; the
monorepo just keeps them in one place.

## Apps

- **`apps/www`** — `www.f3liz.casa`, the main landing page. Vite + Preact,
  deployed to Cloudflare Workers (static assets). Also serves the `yukari-rubi`
  pages.
- **`apps/tsubaki`** — `tsubaki.f3liz.casa`, the project page for
  [Tsubaki](https://github.com/nyanrus/tsubaki), a toy Julia-like language in
  OCaml. A single static page (no build step), deployed to Cloudflare Workers.
- **`apps/transit`** — the transit dashboard (GPS traces / route correction).
  Node + Julia, containerized and deployed with Kamal — not a Cloudflare app,
  so it sits outside the npm workspaces.

## Working on it

`apps/www` and `apps/tsubaki` are npm workspaces:

```sh
npm install                 # once, from the root
npm run deploy:www          # vite build && wrangler deploy, in apps/www
npm run deploy:tsubaki      # wrangler deploy, in apps/tsubaki
```

`apps/transit` has its own README and its own Kamal-based deploy — see
`apps/transit/README.md`.
