#!/usr/bin/env node
// patch-receipt.mjs — neutralize Tweetbot's Mac App Store anti-tamper exits so the
// re-signed app launches and keeps running. Patches the arm64 slice in place.
//
//  1) Receipt gate in main(): `cmp x23,#3 ; b.ne <exit173>` just before
//     _NSApplicationMain. Replace the b.ne with NOP so main falls through to launch.
//
//  2) Delayed watchdogs: several dispatch-timer handlers, each a 4-instruction stub
//        stp x29,x30,[sp,#-0x10]! ; mov x29,sp ; mov w0,#0 ; bl _exit
//     armed at launch and only cancelled if validation passes. They fire at staggered
//     intervals and exit(0). We find every stub by that exact signature and replace
//     its first instruction with RET, turning each into a no-op.
//
// Verifies instructions before writing; idempotent. Usage: node patch-receipt.mjs <mach-o>
import { readFileSync, writeFileSync } from "node:fs";

const FAT_MAGIC = 0xcafebabe, FAT_MAGIC_64 = 0xcafebabf;
const CPU_ARM64 = 0x0100000c;
const TEXT_VMADDR = 0x100000000n;

const NOP = 0xd503201f, RET = 0xd65f03c0;
const STP_FP = 0xa9bf7bfd;   // stp x29, x30, [sp, #-0x10]!
const MOV_FP = 0x910003fd;   // mov x29, sp
const MOV_W0 = 0x52800000;   // mov w0, #0
const isBL = (w) => (w >>> 26) === 0x25;

const file = process.argv[2];
if (!file) { console.error("usage: node patch-receipt.mjs <mach-o>"); process.exit(2); }
const buf = readFileSync(file);

// locate arm64 slice
let sliceOffset = 0;
const top = buf.readUInt32BE(0);
if (top === FAT_MAGIC || top === FAT_MAGIC_64) {
  const is64 = top === FAT_MAGIC_64, n = buf.readUInt32BE(4);
  let p = 8, found = false;
  for (let i = 0; i < n; i++) {
    const cpu = buf.readUInt32BE(p);
    const off = is64 ? Number(buf.readBigUInt64BE(p + 8)) : buf.readUInt32BE(p + 8);
    if (cpu === CPU_ARM64) { sliceOffset = off; found = true; }
    p += is64 ? 32 : 20;
  }
  if (!found) { console.error("no arm64 slice"); process.exit(1); }
}

let changed = false;

// (1) receipt gate: b.ne (B.cond, NE) -> NOP
{
  const off = sliceOffset + Number(0x100001ed4n - TEXT_VMADDR);
  const cur = buf.readUInt32LE(off);
  if (cur === NOP) console.log("already applied: receipt gate b.ne -> NOP");
  else if (((cur & 0xff00001f) >>> 0) === 0x54000001) {
    buf.writeUInt32LE(NOP, off); changed = true;
    console.log("patched: receipt gate b.ne -> NOP @ 0x100001ed4");
  } else { console.error(`unexpected 0x${cur.toString(16)} at receipt gate; refusing`); process.exit(1); }
}

// (2) scan __text window for kill-stub signature and RET each entry
let stubs = 0;
for (let f = sliceOffset; f < sliceOffset + 0x180000 - 16; f += 4) {
  if (buf.readUInt32LE(f) === STP_FP &&
      buf.readUInt32LE(f + 4) === MOV_FP &&
      buf.readUInt32LE(f + 8) === MOV_W0 &&
      isBL(buf.readUInt32LE(f + 12))) {
    const vm = 0x100000000 + (f - sliceOffset);
    buf.writeUInt32LE(RET, f); changed = true; stubs++;
    console.log(`patched: watchdog stub -> RET @ 0x${vm.toString(16)}`);
  } else if (buf.readUInt32LE(f) === RET &&
             buf.readUInt32LE(f + 4) === MOV_FP &&
             buf.readUInt32LE(f + 8) === MOV_W0 &&
             isBL(buf.readUInt32LE(f + 12))) {
    stubs++; // already patched
  }
}
console.log(`watchdog stubs handled: ${stubs}`);
if (changed) writeFileSync(file, buf);
