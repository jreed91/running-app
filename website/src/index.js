// Serves https://runwithstride.app: the Stride landing page (public/index.html),
// race invites (public/race.html), the privacy policy and support pages, and
// the app-site association file. Old /stride/... paths (from when the site
// lived at jacobreed.dev/stride) redirect to their new homes.

// Pages served from public/<name>.html at /<name>.
const PAGES = new Set(['/race', '/privacy', '/support']);

const LEGACY = {
  '/stride': '/',
  '/index.html': '/',
  '/stride/privacy': '/privacy',
  '/stride/support': '/support',
  '/stride/race': '/race'
};

// iOS reads this to decide which links open Stride: a race invite shared from
// the app (running-app RaceInvite.swift) opens the app when it is installed.
const APP_SITE_ASSOCIATION = {
  applinks: {
    details: [
      {
        appIDs: ['VMNPGK3Q29.com.running.stride'],
        components: [
          { '/': '/race', comment: 'Stride race invites' },
          { '/': '/race/', comment: 'The same, with a trailing slash' }
        ]
      }
    ]
  }
};

const SECURITY_HEADERS = {
  'X-Content-Type-Options': 'nosniff',
  'Referrer-Policy': 'strict-origin-when-cross-origin',
  'X-Frame-Options': 'SAMEORIGIN',
  'Permissions-Policy': 'camera=(), microphone=(), geolocation=()'
};

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.hostname.startsWith('www.')) {
      url.hostname = url.hostname.slice(4);
      return Response.redirect(url.toString(), 301);
    }

    const path = url.pathname.replace(/\/+$/, '') || '/';

    if (path === '/.well-known/apple-app-site-association') {
      return Response.json(APP_SITE_ASSOCIATION);
    }

    if (LEGACY[path]) {
      const target = new URL(LEGACY[path], url);
      target.search = url.search;
      return Response.redirect(target.toString(), 301);
    }

    let assetPath;
    if (path === '/') {
      assetPath = '/';
    } else if (PAGES.has(path)) {
      // Extensionless, so the assets' html handling doesn't redirect. A race
      // invite keeps its race in the query string, which the page reads.
      assetPath = path;
    } else if (url.pathname.startsWith('/stride/img/')) {
      assetPath = url.pathname.slice('/stride'.length);
    } else if (url.pathname.startsWith('/img/')) {
      assetPath = url.pathname;
    } else {
      return Response.redirect(new URL('/', url).toString(), 302);
    }

    const assetUrl = new URL(assetPath, url);
    const response = await env.ASSETS.fetch(new Request(assetUrl, request));
    const withHeaders = new Response(response.body, response);
    for (const [key, value] of Object.entries(SECURITY_HEADERS)) {
      withHeaders.headers.set(key, value);
    }
    return withHeaders;
  }
};
