import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright-core';

const here = new URL('./', import.meta.url);
const modules = new URL('../../node_modules/', here);
const assets = new Map([
  ['/', [new URL('terminal.html', here), 'text/html']],
  ['/xterm.mjs', [new URL('@xterm/xterm/lib/xterm.mjs', modules), 'text/javascript']],
  ['/xterm.css', [new URL('@xterm/xterm/css/xterm.css', modules), 'text/css']],
  ...[['regular', '400-normal'], ['bold', '700-normal'], ['italic', '400-italic']]
    .map(([name, variant]) => [
      `/${name}.woff2`,
      [new URL(`@fontsource/jetbrains-mono/files/jetbrains-mono-latin-${variant}.woff2`, modules), 'font/woff2'],
    ]),
]);
const output = process.argv[2];
if (!output) throw new Error('Usage: node scripts/screenshot/render.mjs output.png < capture.ansi');
let capture = '';
process.stdin.setEncoding('utf8');
for await (const chunk of process.stdin) capture += chunk;

const browser = await chromium.launch({
  executablePath: process.env.CHROMIUM_BIN || undefined,
});
try {
  const page = await browser.newPage({
    viewport: { width: 1200, height: 850 },
    deviceScaleFactor: 2,
  });
  // Serve only these local npm assets; rendering does not need a server or CDN.
  await page.route('**/*', async route => {
    const asset = assets.get(new URL(route.request().url()).pathname);
    if (!asset) return route.abort();
    const [file, contentType] = asset;
    await route.fulfill({ body: await readFile(fileURLToPath(file)), contentType });
  });
  await page.goto('http://pim.screenshot/');
  await page.waitForFunction(() => typeof window.render === 'function');
  await page.evaluate(capture => window.render(capture), capture);
  const box = await page.locator('#window').boundingBox();
  await page.setViewportSize({
    width: Math.ceil(box.x + box.width + 56),
    height: Math.ceil(box.y + box.height + 64),
  });
  await page.screenshot({ path: output });
} finally {
  await browser.close();
}
