#!/usr/bin/env node
// insert-dylib.mjs — add an LC_LOAD_DYLIB command to a Mach-O (thin or universal),
// reusing the zero padding between the load commands and the first section data.
// No external deps; pure Buffer surgery. macOS arm64/x86_64 (little-endian) targets.
//
// Usage: node insert-dylib.mjs <mach-o> <dylib-install-path> [--weak]
//
// After patching you MUST re-sign the binary (codesign), because we changed its bytes.

import { readFileSync, writeFileSync } from "node:fs";

const FAT_MAGIC = 0xcafebabe;
const FAT_MAGIC_64 = 0xcafebabf;
const MH_MAGIC_64 = 0xfeedfacf; // 64-bit, little-endian on disk => bytes cf fa ed fe
const LC_LOAD_DYLIB = 0x0c;
const LC_LOAD_WEAK_DYLIB = 0x80000018;

const [, , file, dylibPath, ...rest] = process.argv;
if (!file || !dylibPath) {
  console.error("usage: node insert-dylib.mjs <mach-o> <dylib-install-path> [--weak]");
  process.exit(2);
}
const weak = rest.includes("--weak");
const buf = readFileSync(file);

function buildLoadCommand(path, weak) {
  // struct dylib_command: cmd, cmdsize, dylib{ name.offset, timestamp, current_version, compat_version }
  const nameBytes = Buffer.from(path + "\0", "utf8");
  const headerLen = 24; // 6 * uint32
  let cmdsize = headerLen + nameBytes.length;
  cmdsize = (cmdsize + 7) & ~7; // 8-byte align
  const cmd = Buffer.alloc(cmdsize);
  cmd.writeUInt32LE(weak ? LC_LOAD_WEAK_DYLIB : LC_LOAD_DYLIB, 0);
  cmd.writeUInt32LE(cmdsize, 4);
  cmd.writeUInt32LE(headerLen, 8); // name offset within the command
  cmd.writeUInt32LE(2, 12); // timestamp
  cmd.writeUInt32LE(0x10000, 16); // current_version 1.0.0
  cmd.writeUInt32LE(0x10000, 20); // compat_version 1.0.0
  nameBytes.copy(cmd, headerLen);
  return cmd;
}

// Patch one thin slice starting at sliceOffset. Returns a human label.
function patchThin(buf, sliceOffset) {
  const magic = buf.readUInt32LE(sliceOffset);
  if (magic !== MH_MAGIC_64) {
    throw new Error(
      `slice at 0x${sliceOffset.toString(16)}: unsupported magic 0x${magic.toString(16)} (only 64-bit LE supported)`
    );
  }
  const cpuType = buf.readInt32LE(sliceOffset + 4);
  const ncmdsOff = sliceOffset + 16;
  const sizeofcmdsOff = sliceOffset + 20;
  let ncmds = buf.readUInt32LE(ncmdsOff);
  let sizeofcmds = buf.readUInt32LE(sizeofcmdsOff);
  const headerSize = 32; // mach_header_64
  const loadCmdsStart = sliceOffset + headerSize;
  const loadCmdsEnd = loadCmdsStart + sizeofcmds;

  // Walk load commands to (a) detect duplicate, (b) find lowest section file offset
  // that marks the start of real data (the padding ceiling we can grow into).
  const LC_SEGMENT_64 = 0x19;
  let minSectionOffset = Infinity;
  let cursor = loadCmdsStart;
  for (let i = 0; i < ncmds; i++) {
    const c = buf.readUInt32LE(cursor);
    const csize = buf.readUInt32LE(cursor + 4);
    if (c === LC_LOAD_DYLIB || c === LC_LOAD_WEAK_DYLIB) {
      const nameOff = buf.readUInt32LE(cursor + 8);
      const nameStart = cursor + nameOff;
      let end = nameStart;
      while (end < cursor + csize && buf[end] !== 0) end++;
      const name = buf.toString("utf8", nameStart, end);
      if (name === dylibPath) {
        return { cpuType, skipped: true, reason: "already present" };
      }
    }
    if (c === LC_SEGMENT_64) {
      // segment_command_64: ... nsects at offset 64, sections follow at +72
      const nsects = buf.readUInt32LE(cursor + 64);
      let sec = cursor + 72;
      for (let s = 0; s < nsects; s++) {
        // section_64: offset (uint32) is at +48 within the 80-byte struct
        const secOffset = buf.readUInt32LE(sec + 48);
        if (secOffset > 0 && secOffset < minSectionOffset) minSectionOffset = secOffset;
        sec += 80;
      }
    }
    cursor += csize;
  }

  const newCmd = buildLoadCommand(dylibPath, weak);
  const freeSpace = (sliceOffset + minSectionOffset) - loadCmdsEnd;
  if (newCmd.length > freeSpace) {
    throw new Error(
      `slice cpu=${cpuType}: not enough header padding (need ${newCmd.length}, have ${freeSpace}). ` +
      `Would require moving section data — not supported by this simple patcher.`
    );
  }

  // Write the new command right after the existing ones, into zero padding.
  newCmd.copy(buf, loadCmdsEnd);
  buf.writeUInt32LE(ncmds + 1, ncmdsOff);
  buf.writeUInt32LE(sizeofcmds + newCmd.length, sizeofcmdsOff);
  return { cpuType, skipped: false, added: newCmd.length, freeSpace };
}

const cpuName = (t) => (t === 0x0100000c ? "arm64" : t === 0x01000007 ? "x86_64" : `cpu(0x${t.toString(16)})`);

const top = buf.readUInt32BE(0);
const results = [];
if (top === FAT_MAGIC || top === FAT_MAGIC_64) {
  const is64 = top === FAT_MAGIC_64;
  const nfat = buf.readUInt32BE(4);
  let p = 8;
  for (let i = 0; i < nfat; i++) {
    // fat_arch(_64): cputype, cpusubtype, offset, size, align
    let offset;
    if (is64) {
      offset = Number(buf.readBigUInt64BE(p + 8));
      p += 32;
    } else {
      offset = buf.readUInt32BE(p + 8);
      p += 20;
    }
    results.push(patchThin(buf, offset));
  }
} else if (top === 0xcffaedfe || buf.readUInt32LE(0) === MH_MAGIC_64) {
  results.push(patchThin(buf, 0));
} else {
  console.error(`unrecognized file magic 0x${top.toString(16)}`);
  process.exit(1);
}

writeFileSync(file, buf);
for (const r of results) {
  if (r.skipped) console.log(`  ${cpuName(r.cpuType)}: skipped (${r.reason})`);
  else console.log(`  ${cpuName(r.cpuType)}: added LC_LOAD${weak ? "_WEAK" : ""}_DYLIB (+${r.added} bytes, ${r.freeSpace} padding available)`);
}
console.log(`patched: ${file} -> ${dylibPath}`);
