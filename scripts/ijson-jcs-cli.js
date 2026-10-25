#!/usr/bin/env bun
// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// ijson-jcs-cli.js — local Bun fallback matching hyperpolymath/ijson-jcs's CLI
// contract (`check`, `fix`, `canon`) for environments where the compiled Rust
// binary is not yet installed. CI installs and runs hyperpolymath/ijson-jcs
// directly at a pinned commit; both enforce RFC 7493 (I-JSON) + RFC 8785 (JCS)
// as transitional tooling until metadatastician/kyq passes positive/negative
// tests across its four-format scope.

import { readFileSync, writeFileSync } from "node:fs";

const EXIT_OK = 0;
const EXIT_NOT_CANONICAL = 1;
const EXIT_INVALID = 2;
const SAFE_MAX_INT = 9007199254740991n; // 2^53 - 1 (RFC 7493 §2.2)

const USAGE = `ijson-jcs-cli.js - I-JSON (RFC 7493) parsing and JCS (RFC 8785) canonicalisation

USAGE:
    ijson-jcs check FILE...    Report whether each FILE is canonical
    ijson-jcs fix FILE...      Rewrite each valid FILE in canonical form
    ijson-jcs canon            Canonicalise stdin to stdout
`;

/**
 * Decode a buffer strictly as UTF-8 without BOM (RFC 7493 §2.1).
 * @param {Uint8Array} bytes
 * @returns {string}
 */
function decodeStrictUtf8(bytes) {
  if (bytes.length >= 3 && bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf) {
    throw new Error("UTF-8 BOM is forbidden in I-JSON");
  }
  const decoder = new TextDecoder("utf-8", { fatal: true });
  return decoder.decode(bytes);
}

/**
 * Reject Unicode noncharacters and lone surrogates (RFC 7493 §2.1).
 * @param {string} s
 */
function checkStringCodePoints(s) {
  for (let k = 0; k < s.length; k++) {
    const c = s.charCodeAt(k);
    if (c >= 0xd800 && c <= 0xdfff) {
      if (c <= 0xdbff && k + 1 < s.length) {
        const c2 = s.charCodeAt(k + 1);
        if (c2 >= 0xdc00 && c2 <= 0xdfff) {
          const cp = ((c - 0xd800) << 10) + (c2 - 0xdc00) + 0x10000;
          if ((cp & 0xfffe) === 0xfffe) {
            throw new Error(`Unicode noncharacter U+${cp.toString(16).toUpperCase()}`);
          }
          k++;
          continue;
        }
      }
      throw new Error(`lone UTF-16 surrogate 0x${c.toString(16)}`);
    }
    if ((c >= 0xfdd0 && c <= 0xfdef) || c === 0xfffe || c === 0xffff) {
      throw new Error(`Unicode noncharacter U+${c.toString(16).toUpperCase()}`);
    }
  }
}

/**
 * Parse `raw` strictly as RFC 7493 I-JSON, rejecting duplicate keys,
 * integers outside +/-(2^53-1), non-finite floats, lone surrogates,
 * and Unicode noncharacters.
 * @param {string} raw
 */
function parseIJson(raw) {
  let i = 0;
  const n = raw.length;

  function ws() {
    while (i < n) {
      const ch = raw[i];
      if (ch === " " || ch === "\t" || ch === "\n" || ch === "\r") i++;
      else break;
    }
  }

  function parseString() {
    if (raw[i] !== '"') throw new Error(`expected '"' at byte ${i}`);
    i++;
    let out = "";
    while (i < n) {
      const ch = raw[i++];
      if (ch === '"') {
        checkStringCodePoints(out);
        return out;
      }
      if (ch.charCodeAt(0) < 0x20) {
        throw new Error(`unescaped control character at offset ${i - 1}`);
      }
      if (ch === "\\") {
        if (i >= n) throw new Error("unterminated escape sequence");
        const esc = raw[i++];
        if (esc === '"' || esc === "\\" || esc === "/") out += esc;
        else if (esc === "b") out += "\b";
        else if (esc === "f") out += "\f";
        else if (esc === "n") out += "\n";
        else if (esc === "r") out += "\r";
        else if (esc === "t") out += "\t";
        else if (esc === "u") {
          const hex = raw.slice(i, i + 4);
          if (!/^[0-9a-fA-F]{4}$/.test(hex)) throw new Error("invalid \\u escape");
          i += 4;
          const cp = parseInt(hex, 16);
          if (cp >= 0xd800 && cp <= 0xdbff) {
            if (raw.slice(i, i + 2) !== "\\u") throw new Error("unpaired high surrogate");
            const hex2 = raw.slice(i + 2, i + 6);
            if (!/^[0-9a-fA-F]{4}$/.test(hex2)) throw new Error("invalid low surrogate escape");
            const cp2 = parseInt(hex2, 16);
            if (cp2 < 0xdc00 || cp2 > 0xdfff) throw new Error("unpaired high surrogate");
            i += 6;
            out += String.fromCodePoint(((cp - 0xd800) << 10) + (cp2 - 0xdc00) + 0x10000);
          } else if (cp >= 0xdc00 && cp <= 0xdfff) {
            throw new Error("unpaired low surrogate");
          } else {
            out += String.fromCharCode(cp);
          }
        } else {
          throw new Error(`invalid escape '\\${esc}'`);
        }
      } else {
        out += ch;
      }
    }
    throw new Error("unterminated string");
  }

  function parseNumber() {
    const start = i;
    if (raw[i] === "-") i++;
    if (i >= n) throw new Error("incomplete number");
    if (raw[i] === "0") {
      i++;
      if (i < n && raw[i] >= "0" && raw[i] <= "9") {
        throw new Error("leading zero in number");
      }
    } else if (raw[i] >= "1" && raw[i] <= "9") {
      while (i < n && raw[i] >= "0" && raw[i] <= "9") i++;
    } else {
      throw new Error(`invalid number at offset ${start}`);
    }
    let isFloat = false;
    if (i < n && raw[i] === ".") {
      isFloat = true;
      i++;
      if (i >= n || raw[i] < "0" || raw[i] > "9") throw new Error("missing fraction digits");
      while (i < n && raw[i] >= "0" && raw[i] <= "9") i++;
    }
    if (i < n && (raw[i] === "e" || raw[i] === "E")) {
      isFloat = true;
      i++;
      if (i < n && (raw[i] === "+" || raw[i] === "-")) i++;
      if (i >= n || raw[i] < "0" || raw[i] > "9") throw new Error("missing exponent digits");
      while (i < n && raw[i] >= "0" && raw[i] <= "9") i++;
    }
    const token = raw.slice(start, i);
    if (!isFloat) {
      const mag = BigInt(token.startsWith("-") ? token.slice(1) : token);
      if (mag > SAFE_MAX_INT) {
        throw new Error(`integer ${token} exceeds IEEE-754 safe range +/-(2^53-1)`);
      }
    }
    const num = Number(token);
    if (!Number.isFinite(num)) {
      throw new Error(`number ${token} overflows IEEE-754 double`);
    }
    return Object.is(num, -0) ? 0 : num;
  }

  function parseValue() {
    ws();
    if (i >= n) throw new Error("unexpected end of input");
    const ch = raw[i];
    if (ch === '"') return parseString();
    if (ch === "-" || (ch >= "0" && ch <= "9")) return parseNumber();
    if (ch === "{") {
      i++;
      ws();
      const obj = new Map();
      if (raw[i] === "}") {
        i++;
        return obj;
      }
      let closedObj = false;
      while (i < raw.length) {
        ws();
        const key = parseString();
        if (obj.has(key)) {
          throw new Error(`duplicate object key ${JSON.stringify(key)}`);
        }
        ws();
        if (raw[i] !== ":") throw new Error(`expected ':' after key ${JSON.stringify(key)}`);
        i++;
        const val = parseValue();
        obj.set(key, val);
        ws();
        if (raw[i] === ",") {
          i++;
          continue;
        }
        if (raw[i] === "}") {
          i++;
          closedObj = true;
          break;
        }
        throw new Error(`expected ',' or '}' at offset ${i}`);
      }
      if (!closedObj) throw new Error("unterminated object");
      return obj;
    }
    if (ch === "[") {
      i++;
      ws();
      const arr = [];
      if (raw[i] === "]") {
        i++;
        return arr;
      }
      let closedArr = false;
      while (i < raw.length) {
        arr.push(parseValue());
        ws();
        if (raw[i] === ",") {
          i++;
          continue;
        }
        if (raw[i] === "]") {
          i++;
          closedArr = true;
          break;
        }
        throw new Error(`expected ',' or ']' at offset ${i}`);
      }
      if (!closedArr) throw new Error("unterminated array");
      return arr;
    }
    if (raw.slice(i, i + 4) === "true") {
      i += 4;
      return true;
    }
    if (raw.slice(i, i + 5) === "false") {
      i += 5;
      return false;
    }
    if (raw.slice(i, i + 4) === "null") {
      i += 4;
      return null;
    }
    throw new Error(`unexpected token at offset ${i}`);
  }

  const val = parseValue();
  ws();
  if (i !== n) throw new Error(`trailing characters at offset ${i}`);
  return val;
}

/**
 * Compare two strings by UTF-16 code units (RFC 8785 §3.2.3).
 * @param {string} a
 * @param {string} b
 */
function compareUtf16(a, b) {
  const len = Math.min(a.length, b.length);
  for (let idx = 0; idx < len; idx++) {
    const diff = a.charCodeAt(idx) - b.charCodeAt(idx);
    if (diff !== 0) return diff;
  }
  return a.length - b.length;
}

/**
 * Serialize a validated value into RFC 8785 (JCS) canonical form.
 * @param {unknown} val
 * @returns {string}
 */
function serializeJcs(val) {
  if (val === null || typeof val === "boolean" || typeof val === "number" || typeof val === "string") {
    return JSON.stringify(val);
  }
  if (Array.isArray(val)) {
    return "[" + val.map(serializeJcs).join(",") + "]";
  }
  if (val instanceof Map) {
    const keys = [...val.keys()].sort(compareUtf16);
    return "{" + keys.map((k) => JSON.stringify(k) + ":" + serializeJcs(val.get(k))).join(",") + "}";
  }
  throw new Error("unsupported JSON value");
}

function canonicalString(bytes) {
  const text = decodeStrictUtf8(bytes);
  const parsed = parseIJson(text);
  return serializeJcs(parsed);
}

const encoder = new TextEncoder();

function cmdCheck(files) {
  let code = EXIT_OK;
  for (const path of files) {
    let bytes;
    try {
      bytes = readFileSync(path);
    } catch (err) {
      console.log(`INVALID ${path}: cannot read: ${err.message}`);
      code = EXIT_INVALID;
      continue;
    }
    try {
      const canon = encoder.encode(canonicalString(bytes));
      const stripped =
        bytes.length > 0 && bytes[bytes.length - 1] === 0x0a
          ? bytes.subarray(0, bytes.length - 1)
          : bytes;
      let eq = stripped.length === canon.length;
      if (eq) {
        for (let idx = 0; idx < canon.length; idx++) {
          if (stripped[idx] !== canon[idx]) {
            eq = false;
            break;
          }
        }
      }
      if (eq) {
        console.log(`OK ${path}`);
      } else {
        console.log(`NOT CANONICAL ${path}`);
        code = Math.max(code, EXIT_NOT_CANONICAL);
      }
    } catch (err) {
      console.log(`INVALID ${path}: ${err.message}`);
      code = EXIT_INVALID;
    }
  }
  return code;
}

function cmdFix(files) {
  let code = EXIT_OK;
  for (const path of files) {
    let bytes;
    try {
      bytes = readFileSync(path);
    } catch (err) {
      console.log(`INVALID ${path}: cannot read: ${err.message}`);
      code = EXIT_INVALID;
      continue;
    }
    let canonBytes;
    try {
      canonBytes = encoder.encode(canonicalString(bytes) + "\n");
    } catch (err) {
      console.log(`INVALID ${path}: ${err.message}`);
      code = EXIT_INVALID;
      continue;
    }
    let same = bytes.length === canonBytes.length;
    if (same) {
      for (let idx = 0; idx < canonBytes.length; idx++) {
        if (bytes[idx] !== canonBytes[idx]) {
          same = false;
          break;
        }
      }
    }
    if (same) {
      console.log(`OK ${path}`);
    } else {
      try {
        writeFileSync(path, canonBytes);
        console.log(`FIXED ${path}`);
      } catch (err) {
        console.log(`INVALID ${path}: cannot write: ${err.message}`);
        code = EXIT_INVALID;
      }
    }
  }
  return code;
}

function cmdCanon() {
  let bytes;
  try {
    bytes = readFileSync(0);
  } catch (err) {
    console.error(`INVALID <stdin>: cannot read: ${err.message}`);
    return EXIT_INVALID;
  }
  try {
    process.stdout.write(canonicalString(bytes));
    return EXIT_OK;
  } catch (err) {
    console.error(`INVALID <stdin>: ${err.message}`);
    return EXIT_INVALID;
  }
}

const args = process.argv.slice(2);
if (args.includes("-h") || args.includes("--help")) {
  process.stdout.write(USAGE);
  process.exit(EXIT_OK);
}
if (args.includes("-V") || args.includes("--version")) {
  console.log("ijson-jcs-cli.js 0.1.0");
  process.exit(EXIT_OK);
}
if (args.length === 0) {
  console.error("ijson-jcs: missing command");
  process.exit(EXIT_INVALID);
}
const [cmd, ...rest] = args;
const files = rest[0] === "--" ? rest.slice(1) : rest;
if (rest[0] !== "--") {
  const badOpt = rest.find((a) => a.startsWith("-") && a.length > 1);
  if (badOpt) {
    console.error(`ijson-jcs: unknown option '${badOpt}'`);
    process.exit(EXIT_INVALID);
  }
}
if ((cmd === "check" || cmd === "fix") && files.length === 0) {
  console.error(`ijson-jcs: '${cmd}' needs at least one FILE`);
  process.exit(EXIT_INVALID);
}
if (cmd === "check") process.exit(cmdCheck(files));
if (cmd === "fix") process.exit(cmdFix(files));
if (cmd === "canon") {
  if (files.length > 0) {
    console.error("ijson-jcs: 'canon' reads stdin and takes no FILE");
    process.exit(EXIT_INVALID);
  }
  process.exit(cmdCanon());
}
console.error(`ijson-jcs: unknown command '${cmd}'`);
process.exit(EXIT_INVALID);
