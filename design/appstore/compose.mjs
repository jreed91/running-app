// Frames raw App Store screenshots in the Route Loop style: the night-map ground, an
// orange eyebrow and a headline, and the screen in a device-shaped frame.
//
//   node design/appstore/compose.mjs <raw-dir> <out-dir> [chromium|webkit] [iphone|duo-inner|duo-outer]
//
// Reads captions.json beside this file; writes one PNG per caption whose raw file exists
// (named `out` when the caption has one, so the files sort in listing order),
// at the App Store Connect size for the device: 1320 x 2868 for the 6.9" iPhone (the
// default), 2007 x 2853 for the iPhone Duo inner display, 1398 x 2034 for its outer one.
// WebKit is the default because it renders `ui-rounded` as SF Pro Rounded on macOS, as
// the app does.
import { readFileSync, writeFileSync, unlinkSync, existsSync, mkdirSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createRequire } from 'node:module';

// `require` rather than `import` so a global install found through NODE_PATH works too.
const playwright = createRequire(import.meta.url)('playwright');

const here = dirname(fileURLToPath(import.meta.url));
const [rawDir, outDir, engine = 'webkit', device = 'iphone'] = process.argv.slice(2);
// Portrait App Store Connect sizes, and the device's corner radius at the iPhone's scale.
const devices = {
  iphone: { width: 1320, height: 2868, radius: 150 },
  'duo-inner': { width: 2007, height: 2853, radius: 96 },
  'duo-outer': { width: 1398, height: 2034, radius: 150 },
};
if (!rawDir || !outDir || !devices[device]) {
  console.error('usage: node compose.mjs <raw-dir> <out-dir> [chromium|webkit] [iphone|duo-inner|duo-outer]');
  process.exit(2);
}
const { width, height, radius } = devices[device];

// The iPhone layout (designed at 1320 x 2868) scaled to fit the canvas: the copy keeps its
// place, and the device fills the rest down to a 60px margin, its screen at the canvas
// aspect so the raw capture is never cropped.
const s = Math.min(width / 1320, height / 2868);
const bezel = 26 * s;
const devTop = 700 * s;
const devHeight = height - devTop - 60 * s;
const devWidth = (devHeight - 2 * bezel) * (width / height) + 2 * bezel;
const geometry = [
  `--w:${width}px`, `--h:${height}px`, `--s:${s}`, `--bezel:${bezel}px`,
  `--dev-top:${devTop}px`, `--dev-w:${devWidth}px`, `--dev-h:${devHeight}px`,
  `--radius:${radius * s}px`, `--screen-radius:${(radius - 26) * s}px`,
].join('; ');
const { iphone } = JSON.parse(readFileSync(join(here, 'captions.json'), 'utf8'));
const template = readFileSync(join(here, 'frame.html'), 'utf8');
mkdirSync(outDir, { recursive: true });

const escape = (s) => s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);

const browser = await playwright[engine].launch();
const page = await browser.newPage({ viewport: { width, height }, deviceScaleFactor: 1 });
let made = 0;
for (const shot of iphone) {
  const raw = resolve(rawDir, shot.file);
  if (!existsSync(raw)) {
    console.warn(`skip ${shot.file}: no raw screenshot`);
    continue;
  }
  const html = template
    .replace('{{GEOMETRY}}', geometry)
    .replace('{{EYEBROW}}', escape(shot.eyebrow))
    .replace('{{TITLE}}', escape(shot.title))
    .replace('{{SCREEN}}', pathToFileURL(raw).href);
  const tmp = join(outDir, `.${shot.file}.html`);
  writeFileSync(tmp, html);
  await page.goto(pathToFileURL(tmp).href);
  await page.waitForLoadState('load');
  await page.screenshot({ path: join(outDir, shot.out ?? shot.file), omitBackground: false });
  unlinkSync(tmp);
  made += 1;
  console.log(`framed ${shot.file} as ${shot.out ?? shot.file}`);
}
await browser.close();
if (made === 0) {
  console.error('No raw screenshots found.');
  process.exit(1);
}
