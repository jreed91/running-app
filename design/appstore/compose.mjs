// Frames raw App Store screenshots in the Route Loop style: the night-map ground, an
// orange eyebrow and a headline, and the screen in a device-shaped frame.
//
//   node design/appstore/compose.mjs <raw-dir> <out-dir> [chromium|webkit]
//
// Reads captions.json beside this file; writes one 1320 x 2868 PNG (the 6.9" iPhone
// size App Store Connect requires) per caption whose raw file exists. WebKit is the
// default because it renders `ui-rounded` as SF Pro Rounded on macOS, as the app does.
import { readFileSync, writeFileSync, unlinkSync, existsSync, mkdirSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createRequire } from 'node:module';

// `require` rather than `import` so a global install found through NODE_PATH works too.
const playwright = createRequire(import.meta.url)('playwright');

const here = dirname(fileURLToPath(import.meta.url));
const [rawDir, outDir, engine = 'webkit'] = process.argv.slice(2);
if (!rawDir || !outDir) {
  console.error('usage: node compose.mjs <raw-dir> <out-dir> [chromium|webkit]');
  process.exit(2);
}
const { iphone } = JSON.parse(readFileSync(join(here, 'captions.json'), 'utf8'));
const template = readFileSync(join(here, 'frame.html'), 'utf8');
mkdirSync(outDir, { recursive: true });

const escape = (s) => s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);

const browser = await playwright[engine].launch();
const page = await browser.newPage({ viewport: { width: 1320, height: 2868 }, deviceScaleFactor: 1 });
let made = 0;
for (const shot of iphone) {
  const raw = resolve(rawDir, shot.file);
  if (!existsSync(raw)) {
    console.warn(`skip ${shot.file}: no raw screenshot`);
    continue;
  }
  const html = template
    .replace('{{EYEBROW}}', escape(shot.eyebrow))
    .replace('{{TITLE}}', escape(shot.title))
    .replace('{{SCREEN}}', pathToFileURL(raw).href);
  const tmp = join(outDir, `.${shot.file}.html`);
  writeFileSync(tmp, html);
  await page.goto(pathToFileURL(tmp).href);
  await page.waitForLoadState('load');
  await page.screenshot({ path: join(outDir, shot.file), omitBackground: false });
  unlinkSync(tmp);
  made += 1;
  console.log(`framed ${shot.file}`);
}
await browser.close();
if (made === 0) {
  console.error('No raw screenshots found.');
  process.exit(1);
}
