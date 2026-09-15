// Run from adapter-mac: node scripts/sync-caesar-sphere.mjs
// Uses Caesar's installed Three.js/esbuild only at generation time. Runtime is offline.
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const caesar = path.resolve(root, '../caesar');
const require = createRequire(path.join(caesar, 'package.json'));
const { build } = require('esbuild');
const source = fs.readFileSync(path.join(caesar, 'src/components/common/AgentAvatar.tsx'), 'utf8');
const names = ['SIMPLEX_NOISE_GLSL', 'VERTEX_SHADER', 'FRAGMENT_SHADER_V2', 'WIREFRAME_FRAGMENT_SHADER', 'OUTLINE_FRAGMENT_SHADER'];
const shaders = names.map(name => {
  const match = source.match(new RegExp('const ' + name + ' = /\\* glsl \\*/`([\\s\\S]*?)`;'));
  if (!match) throw new Error('Missing Caesar shader: ' + name);
  return 'const ' + name + ' = `' + match[1] + '`;';
}).join('\n');
const runtime = fs.readFileSync(path.join(root, 'scripts/caesar-sphere-runtime.js'), 'utf8');
await build({ stdin: { contents: "import * as THREE from 'three';\n" + shaders + '\n' + runtime, resolveDir: caesar },
  bundle: true, minify: true, format: 'iife', legalComments: 'eof',
  outfile: path.join(root, 'stts/Resources/Brand/caesar-sphere.js') });
