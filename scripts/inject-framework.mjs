#!/usr/bin/env node
// inject-framework.mjs — add an LC_LOAD_DYLIB to a Mach-O in place, using the free
// header padding between the end of the load commands and the first section.
//
// The main Tweetbot executable has only 16 bytes of padding (too little), but
// PTHCommon.framework has ~5 KB — and Tweetbot loads PTHCommon at launch, so our
// dylib's constructor still runs. Injecting here needs no relocation (unlike the
// main binary, which required LIEF), so the whole pipeline is dependency-free.
//
// Usage: node inject-framework.mjs <mach-o> <install-path>
import { readFileSync, writeFileSync } from "node:fs";

const LC_LOAD_DYLIB = 0x0c;
const CPU_ARM64 = 0x0100000c, CPU_X86_64 = 0x01000007;

const file = process.argv[2];
const installPath = process.argv[3];
if (!file || !installPath) { console.error("usage: node inject-framework.mjs <mach-o> <install-path>"); process.exit(2); }

const buf = readFileSync(file);

// Collect slice offsets (fat) or the single thin slice.
const slices = [];
const top = buf.readUInt32BE(0);
if (top === 0xcafebabe || top === 0xcafebabf) {
  const is64 = top === 0xcafebabf, n = buf.readUInt32BE(4);
  let p = 8;
  for (let i = 0; i < n; i++) {
    const cpu = buf.readUInt32BE(p);
    const off = is64 ? Number(buf.readBigUInt64BE(p + 8)) : buf.readUInt32BE(p + 8);
    if (cpu === CPU_ARM64 || cpu === CPU_X86_64) slices.push(off);
    p += is64 ? 32 : 20;
  }
} else {
  slices.push(0); // thin
}

function buildCommand(path) {
  const pathLen = Buffer.byteLength(path, "utf8") + 1; // + NUL
  const cmdsize = Math.ceil((24 + pathLen) / 8) * 8;    // 8-byte aligned
  const cmd = Buffer.alloc(cmdsize);
  cmd.writeUInt32LE(LC_LOAD_DYLIB, 0);
  cmd.writeUInt32LE(cmdsize, 4);
  cmd.writeUInt32LE(24, 8);          // dylib.name.offset
  cmd.writeUInt32LE(2, 12);          // timestamp
  cmd.writeUInt32LE(0x010000, 16);   // current_version 1.0.0
  cmd.writeUInt32LE(0x010000, 20);   // compatibility_version 1.0.0
  cmd.write(path, 24, "utf8");
  return cmd;
}

const newCmd = buildCommand(installPath);
let injected = 0;

for (const slice of slices) {
  const magic = buf.readUInt32LE(slice);
  if (magic !== 0xfeedfacf) { console.error(`slice @${slice}: not 64-bit Mach-O (0x${magic.toString(16)})`); continue; }
  const ncmds = buf.readUInt32LE(slice + 16);
  const sizeofcmds = buf.readUInt32LE(slice + 20);
  const endLC = slice + 32 + sizeofcmds;

  // idempotency: already injected this path?
  let already = false, p = slice + 32;
  for (let i = 0; i < ncmds; i++) {
    const cmd = buf.readUInt32LE(p), sz = buf.readUInt32LE(p + 4);
    if (cmd === LC_LOAD_DYLIB) {
      const nameOff = buf.readUInt32LE(p + 8);
      let s = p + nameOff, e = s; while (buf[e] !== 0) e++;
      if (buf.toString("utf8", s, e) === installPath) { already = true; break; }
    }
    p += sz;
  }
  if (already) { console.log(`slice @${slice}: already injected`); injected++; continue; }

  // find first section file offset to know the padding ceiling
  let firstSectOff = Infinity; p = slice + 32;
  for (let i = 0; i < ncmds; i++) {
    const cmd = buf.readUInt32LE(p), sz = buf.readUInt32LE(p + 4);
    if (cmd === 0x19) { // LC_SEGMENT_64
      const nsects = buf.readUInt32LE(p + 64); let s = p + 72;
      for (let j = 0; j < nsects; j++) { const fo = buf.readUInt32LE(s + 48); if (fo > 0) firstSectOff = Math.min(firstSectOff, slice + fo); s += 80; }
    }
    p += sz;
  }
  const headroom = (firstSectOff === Infinity ? buf.length : firstSectOff) - endLC;
  if (headroom < newCmd.length) { console.error(`slice @${slice}: not enough header padding (${headroom} < ${newCmd.length})`); process.exit(1); }

  newCmd.copy(buf, endLC);
  buf.writeUInt32LE(ncmds + 1, slice + 16);
  buf.writeUInt32LE(sizeofcmds + newCmd.length, slice + 20);
  console.log(`slice @${slice}: injected LC_LOAD_DYLIB (${newCmd.length} bytes, ${headroom} free)`);
  injected++;
}

if (!injected) { console.error("no slices injected"); process.exit(1); }
writeFileSync(file, buf);
console.log(`done: ${installPath} -> ${file}`);
