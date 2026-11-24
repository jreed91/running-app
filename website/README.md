# runwithstride.app

Stride's website, served by a Cloudflare Worker (`running-app`, the name Cloudflare gave it when the repo was imported). Everything Stride-related on the web lives here; jacobreed.dev only redirects.

- `public/index.html`: the landing page. `public/race.html`: race invites
  (`/race?name=…&date=…&distance=…`, built by `RaceInvite.swift`).
- `public/img/`: screenshots, icons and the social card.
- `public/privacy.html`, `public/support.html`: the privacy policy and support
  page App Store Connect links to (runwithstride.app/privacy and /support).
  When the app gains a new data flow, update `privacy.html` together with
  `Stride/Resources/PrivacyInfo.xcprivacy`.
- `src/index.js`: routing. `/`, `/race`, `/privacy` and `/support` serve the
  pages, `/.well-known/apple-app-site-association` lets race links open the
  app, old `/stride/...` paths 301 to their new homes (jacobreed.dev/stride/*
  redirects here too), `www.` redirects to the bare domain, and any other path
  redirects to `/`.

## Deploy

Cloudflare Workers Builds deploys on every push to `main`. In the Cloudflare
dashboard: Workers & Pages → `running-app` → Settings → Build, repository
`jreed91/running-app`, root directory `website`, deploy command
`npx wrangler@4 deploy`. The two custom domains in `wrangler.jsonc` attach on
deploy.

Pull requests get a preview build, which runs `npx wrangler preview`. That
command needs the `previews` block in `wrangler.jsonc` (empty is fine), so keep
it there. For the pull request comment to show a link, turn on Preview URLs
(Worker → Domains → Worker URL → Preview) or add `"preview_urls": true`.

By hand, from this folder: `npx wrangler@4 deploy` (logs in to Cloudflare the
first time). Preview locally: `npx wrangler@4 dev`.
