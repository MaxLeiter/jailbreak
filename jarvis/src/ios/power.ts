// Battery / power state via IOKit, called straight from bun through bun:ffi.
// This is the template for every "sense" tool: dlopen a system framework, call
// its C API, marshal the result back to JS. Works on iOS (unsandboxed /var/jb
// process) and on macOS laptops — IOPSCopyPowerSourcesInfo exists on both.
//
// The marshalling trick: instead of reading each CFDictionary field over FFI
// (CFStringCreateWithCString + CFDictionaryGetValue + CFNumberGetValue…, all
// fiddly), we serialize the whole description dict to an XML plist with
// CFPropertyListCreateData and parse that text in JS. Fewer FFI hops, robust.

import { dlopen, FFIType, toArrayBuffer } from "bun:ffi";

const CF = "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation";
const IOKIT = "/System/Library/Frameworks/IOKit.framework/IOKit";
const kCFPropertyListXMLFormat_v1_0 = 100;

const openCF = () =>
  dlopen(CF, {
    CFArrayGetCount: { args: [FFIType.ptr], returns: FFIType.i64 },
    CFArrayGetValueAtIndex: { args: [FFIType.ptr, FFIType.i64], returns: FFIType.ptr },
    CFDataGetLength: { args: [FFIType.ptr], returns: FFIType.i64 },
    CFDataGetBytePtr: { args: [FFIType.ptr], returns: FFIType.ptr },
    CFPropertyListCreateData: {
      args: [FFIType.ptr, FFIType.ptr, FFIType.i32, FFIType.u64, FFIType.ptr],
      returns: FFIType.ptr,
    },
    CFRelease: { args: [FFIType.ptr], returns: FFIType.void },
  });
const openIO = () =>
  dlopen(IOKIT, {
    IOPSCopyPowerSourcesInfo: { args: [], returns: FFIType.ptr },
    IOPSCopyPowerSourcesList: { args: [FFIType.ptr], returns: FFIType.ptr },
    IOPSGetPowerSourceDescription: { args: [FFIType.ptr, FFIType.ptr], returns: FFIType.ptr },
  });

let cf: ReturnType<typeof openCF> | null = null;
let io: ReturnType<typeof openIO> | null = null;
function open() {
  cf ??= openCF();
  io ??= openIO();
}

export interface PowerState {
  level: number | null; // 0..100
  charging: boolean | null;
  state: string | null; // "AC Power" | "Battery Power" | …
  raw?: Record<string, string>;
}

export function readPowerSource(): PowerState {
  if (process.platform !== "darwin") return { level: null, charging: null, state: null };
  open();
  const { symbols: c } = cf!;
  const { symbols: k } = io!;

  const info = k.IOPSCopyPowerSourcesInfo();
  if (!info) return { level: null, charging: null, state: null };
  try {
    const list = k.IOPSCopyPowerSourcesList(info);
    if (!list) return { level: null, charging: null, state: null };
    try {
      const count = Number(c.CFArrayGetCount(list));
      if (count < 1) return { level: null, charging: null, state: "no battery" };

      const src = c.CFArrayGetValueAtIndex(list, 0n);
      const desc = k.IOPSGetPowerSourceDescription(info, src); // borrowed, don't release
      const data = c.CFPropertyListCreateData(null, desc, kCFPropertyListXMLFormat_v1_0, 0n, null);
      if (!data) return { level: null, charging: null, state: null };
      try {
        const len = Number(c.CFDataGetLength(data));
        const bytes = c.CFDataGetBytePtr(data);
        if (!bytes) return { level: null, charging: null, state: null };
        const xml = new TextDecoder().decode(toArrayBuffer(bytes, 0, len));
        const dict = parsePlistDict(xml);
        const cur = num(dict["Current Capacity"]);
        const max = num(dict["Max Capacity"]) || 100;
        return {
          level: cur == null ? null : Math.round((cur / max) * 100),
          charging: dict["Is Charging"] === "true" ? true : dict["Is Charging"] === "false" ? false : null,
          state: dict["Power Source State"] ?? null,
          raw: dict,
        };
      } finally {
        c.CFRelease(data);
      }
    } finally {
      c.CFRelease(list);
    }
  } finally {
    c.CFRelease(info);
  }
}

// Minimal <dict> reader for the flat plist IOPS emits: key → scalar value.
function parsePlistDict(xml: string): Record<string, string> {
  const out: Record<string, string> = {};
  const re = /<key>([^<]*)<\/key>\s*(?:<(integer|real|string)>([^<]*)<\/\2>|<(true|false)\s*\/>)/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(xml))) {
    out[decodeEntities(m[1])] = m[4] ?? decodeEntities(m[3] ?? "");
  }
  return out;
}
function num(v: string | undefined): number | null {
  if (v == null || v === "") return null;
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
}
function decodeEntities(s: string): string {
  return s.replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&");
}
