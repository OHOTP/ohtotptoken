import { mkdir, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import { basename, dirname, extname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Resvg } from '@resvg/resvg-js';

const THUMBNAIL_SIZE = 64;
const projectRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const sourceDir = join(projectRoot, 'uikit/src/main/resources/rawfile/icons');
const outputDir = join(projectRoot, 'uikit/src/main/resources/rawfile/icon_thumbnails');

const entries = (await readdir(sourceDir, { withFileTypes: true }))
  .filter((entry) => entry.isFile() && extname(entry.name).toLowerCase() === '.svg')
  .sort((left, right) => left.name.localeCompare(right.name));

await rm(outputDir, { recursive: true, force: true });
await mkdir(outputDir, { recursive: true });

for (const entry of entries) {
  const svg = await readFile(join(sourceDir, entry.name));
  const natural = new Resvg(svg).render();
  const fitMode = natural.width >= natural.height ? 'width' : 'height';
  const rendered = new Resvg(svg, {
    fitTo: { mode: fitMode, value: THUMBNAIL_SIZE }
  }).render();
  const outputName = basename(entry.name, extname(entry.name)) + '.png';
  await writeFile(join(outputDir, outputName), rendered.asPng());
}

console.log(`Generated ${entries.length} icon thumbnails in ${outputDir}`);
