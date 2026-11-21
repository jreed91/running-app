# runwithstride.app

Stride's website, served by a Cloudflare Worker (`runwithstride`).

- `public/index.html`: the landing page. `public/race.html`: race invites
  (`/race?name=…&date=…&distance=…`, built by `RaceInvite.swift`).
- `public/img/`: screenshots, icons and the social card.
- `src/index.js`: routing. `/` and `/race` serve the pages,
  `/.well-known/apple-app-site-association` lets race links open the app,
  `/privacy` and `/support` redirect to jacobreed.dev/stride/privacy and
  /support (App Store Connect links there), `www.` redirects to the bare
  domain, and any other path redirects to `/`.

## Deploy

Cloudflare Workers Builds deploys on every push to `main`. In the Cloudflare
dashboard: Workers & Pages → `runwithstride` → Settings → Build, repository
`jreed91/running-app`, root directory `website`, deploy command
`npx wrangler@4 deploy`. The two custom domains in `wrangler.jsonc` attach on
deploy.

By hand, from this folder: `npx wrangler@4 deploy` (logs in to Cloudflare the
first time). Preview locally: `npx wrangler@4 dev`.
