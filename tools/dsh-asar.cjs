#!/usr/bin/env node
/**
 * dsh-asar.cjs — DSH 桌面版 app.asar 读取 / 替换 / 重打包 / 自校验工具
 *
 * 用途：当需要修改 DSH 自身行为（例如把某个校验函数改成恒真、或替换硬编码公钥）时，
 * 用它把 app.asar 解开、改一个文件、再原样打包回去。不依赖任何 npm 包。
 *
 * asar 结构（实测 DSH 的 resources\app.asar 就是这个布局）：
 *   [0..3]   UInt32LE = 4                     —— 下一字段长度的长度
 *   [4..7]   UInt32LE = headerPickleSize      —— = jsonSize + 8
 *   [8..11]  UInt32LE = 4
 *   [12..15] UInt32LE = jsonSize              —— header JSON 的字节数
 *   [16..]   header JSON (UTF-8)              —— files 树，每个文件带 offset/size/integrity
 *   之后对齐到 4 字节，数据区开始；offset 都是相对数据区起点的
 *
 * 用法：
 *   node dsh-asar.cjs list    <app.asar> [过滤子串]
 *   node dsh-asar.cjs extract <app.asar> <内部路径> <输出文件>
 *   node dsh-asar.cjs patch   <app.asar> <内部路径> <替换用文件> <输出app.asar>
 *   node dsh-asar.cjs verify  <app.asar> [对照app.asar]
 *   node dsh-asar.cjs fuses   <exe> [--set <name>=0|1 ...]
 */
'use strict';
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

// ---------------------------------------------------------------- asar 读
function readAsar(file) {
  const fd = fs.openSync(file, 'r');
  try {
    const b = Buffer.alloc(16);
    fs.readSync(fd, b, 0, 16, 0);
    const headerPickleSize = b.readUInt32LE(4);
    const jsonSize = b.readUInt32LE(12);
    const head = Buffer.alloc(jsonSize);
    fs.readSync(fd, head, 0, jsonSize, 16);
    const dataOffset = 8 + headerPickleSize;
    return {
      fd, file,
      headerPickleSize, jsonSize, dataOffset,
      json: JSON.parse(head.toString('utf8')),
      jsonRaw: head,
    };
  } catch (e) { fs.closeSync(fd); throw e; }
}

function walk(node, prefix, out) {
  for (const name of Object.keys(node.files || {})) {
    const child = node.files[name];
    const p = prefix ? prefix + '/' + name : name;
    if (child.files) walk(child, p, out);
    else out.push({ path: p, node: child });
  }
  return out;
}

function entries(a) { return walk(a.json, '', []); }

function lookup(a, internalPath) {
  const parts = internalPath.split('/').filter(Boolean);
  let node = a.json;
  for (const p of parts) {
    if (!node.files || !node.files[p]) return null;
    node = node.files[p];
  }
  return node;
}

function readEntry(a, node, internalPath) {
  if (node.unpacked) {
    // unpacked 文件物理上在 <asar>.unpacked\<内部路径>，header 里只有 unpacked:true 标记
    const rel = internalPath || node.path || '';
    const unp = a.file + '.unpacked' + path.sep + rel.split('/').join(path.sep);
    return fs.readFileSync(unp);
  }
  const buf = Buffer.alloc(node.size);
  const fd = fs.openSync(a.file, 'r');
  try { fs.readSync(fd, buf, 0, node.size, a.dataOffset + Number(node.offset)); }
  finally { fs.closeSync(fd); }
  return buf;
}

// ---------------------------------------------------------------- asar 写
/**
 * 用 origin 里的内容生成新的 asar；replacement 是 { 内部路径: Buffer }，
 * 只替换列出的文件，其余原样流式复制。
 */
function writeAsar(origin, replacement, outFile) {
  const list = entries(origin);
  const newJson = JSON.parse(JSON.stringify(origin.json));
  const ordered = list.slice().sort((x, y) => Number(x.node.offset) - Number(y.node.offset));

  // 第一遍：只算 offset（相对数据区起点），不改数据
  let cursor = 0;
  const plan = [];
  for (const e of ordered) {
    const target = lookupNode(newJson, e.path);
    if (e.node.unpacked) { target.offset = '0'; continue; }
    const repl = replacement[e.path];
    const size = repl ? repl.length : e.node.size;
    target.size = size;
    target.offset = String(cursor);
    if (repl && target.integrity) {
      target.integrity = integrityFor(repl, target.integrity.blockSize);
    }
    plan.push({ path: e.path, node: e.node, target, size, offset: cursor, repl });
    cursor += size;
  }

  // 由 JSON 长度算出数据区起点，再回填一次（offset 是相对量，不会因起点变化而变）
  const jsonBuf = Buffer.from(JSON.stringify(newJson), 'utf8');
  const paddedLen = jsonBuf.length + padLen(jsonBuf.length);
  const dataOffset = 16 + paddedLen;  // = 8 + headerPickleSize，headerPickleSize = paddedLen + 8

  const srcFd = fs.openSync(origin.file, 'r');
  const dstFd = fs.openSync(outFile, 'w');
  try {
    const CHUNK = 8 * 1024 * 1024;
    const buf = Buffer.alloc(CHUNK);
    for (const item of plan) {
      const wr = dataOffset + item.offset;
      if (item.repl) { fs.writeSync(dstFd, item.repl, 0, item.repl.length, wr); continue; }
      let left = item.size, rd = 0;
      const srcOffset = origin.dataOffset + Number(item.node.offset);
      while (left > 0) {
        const n = fs.readSync(srcFd, buf, 0, Math.min(CHUNK, left), srcOffset + rd);
        if (n <= 0) throw new Error('读取源 asar 失败：' + item.path);
        fs.writeSync(dstFd, buf, 0, n, wr + rd);
        left -= n; rd += n;
      }
    }
    // 用空格补齐到 4 字节对齐：JSON.parse 能容忍尾随空格，且 header 尺寸与实际写入一致
    const padded = Buffer.alloc(paddedLen, 0x20);
    jsonBuf.copy(padded);
    const head = Buffer.alloc(16);
    head.writeUInt32LE(4, 0);              // size pickle 的 payload 长度
    head.writeUInt32LE(paddedLen + 8, 4);  // header pickle 总长 = 8 + JSON 长度
    head.writeUInt32LE(paddedLen + 4, 8);  // header pickle 的 payload 长度 = 4 + JSON 长度
    head.writeUInt32LE(paddedLen, 12);     // JSON 字符串长度（含补齐）
    fs.writeSync(dstFd, head, 0, 16, 0);
    fs.writeSync(dstFd, padded, 0, padded.length, 16);
    fs.ftruncateSync(dstFd, dataOffset + cursor);
  } finally {
    fs.closeSync(dstFd);
    fs.closeSync(srcFd);
  }
  return outFile;
}
/** 按 DSH header 的格式计算文件 integrity（整体 hash + 分块 blocks，hex 编码） */
function integrityFor(buf, blockSize) {
  const bs = blockSize || 4194304;
  const whole = crypto.createHash('sha256').update(buf).digest('hex');
  const blocks = [];
  for (let off = 0; off < buf.length || off === 0; off += bs) {
    blocks.push(crypto.createHash('sha256').update(buf.subarray(off, Math.min(off + bs, buf.length))).digest('hex'));
    if (buf.length === 0) break;
  }
  return { algorithm: 'SHA256', hash: whole, blockSize: bs, blocks };
}
function padLen(n) { return (4 - (n % 4)) % 4; }

function lookupNode(root, internalPath) {
  const parts = internalPath.split('/').filter(Boolean);
  let node = root;
  for (const p of parts) {
    if (!node.files || !node.files[p]) throw new Error('header 里找不到：' + internalPath);
    node = node.files[p];
  }
  return node;
}

// ---------------------------------------------------------------- fuse
const SENTINEL = Buffer.from('dL7pKGdnNz796PbbjQWNKmHXBZaB9tsX', 'utf8');
// @electron/fuses 的 FuseV1Options 顺序
const FUSE_NAMES = [
  'RunAsNode',
  'EnableCookieEncryption',
  'EnableNodeOptionsEnvironmentVariable',
  'EnableNodeCliInspectArguments',
  'EnableEmbeddedAsarIntegrityValidation',
  'OnlyLoadAppFromAsar',
  'LoadBrowserProcessSpecificV8Snapshot',
  'GrantFileProtocolExtraPrivileges',
  'WasmTrapHandlers',
];

function readFuses(exe) {
  const buf = fs.readFileSync(exe);
  const i = buf.indexOf(SENTINEL);
  if (i < 0) throw new Error('exe 里找不到 fuse sentinel');
  const p = i + SENTINEL.length;
  const schemaVersion = buf[p];
  const count = buf[p + 1];
  const rows = [];
  for (let k = 0; k < count; k++) {
    const off = p + 2 + k;
    const ch = String.fromCharCode(buf[off]);
    rows.push({
      index: k,
      name: FUSE_NAMES[k] || ('fuse#' + k),
      state: ch === '1' ? 'ON' : ch === '0' ? 'OFF' : '?(' + ch + ')',
      byteOffset: off,
      ch,
    });
  }
  return { sentinelOffset: i, schemaVersion, count, rows, buffer: buf };
}

// ---------------------------------------------------------------- CLI
function main() {
  const argv = process.argv.slice(2);
  const cmd = argv[0];

  if (cmd === 'list') {
    const a = readAsar(argv[1]);
    const filter = argv[2];
    const list = entries(a).filter(e => !filter || e.path.includes(filter));
    list.slice(0, 500).forEach(e => console.log(e.path + '  ' + e.node.size));
    console.log('--- 共 ' + list.length + ' 个文件（最多显示 500）');
    fs.closeSync(a.fd);
    return;
  }

  if (cmd === 'extract') {
    const a = readAsar(argv[1]);
    const node = lookup(a, argv[2]);
    if (!node) throw new Error('找不到：' + argv[2]);
    const buf = readEntry(a, node, argv[2]);
    fs.writeFileSync(argv[3], buf);
    console.log('已导出 ' + argv[2] + ' -> ' + argv[3] + ' (' + buf.length + ' 字节)');
    fs.closeSync(a.fd);
    return;
  }

  if (cmd === 'patch') {
    const a = readAsar(argv[1]);
    const repl = {}; repl[argv[2]] = fs.readFileSync(argv[3]);
    writeAsar(a, repl, argv[4]);
    fs.closeSync(a.fd);
    const b = readAsar(argv[4]);
    const node = lookup(b, argv[2]);
    console.log('已重打包 -> ' + argv[4]);
    console.log('  替换项新 size = ' + node.size);
    console.log('  文件数 = ' + entries(b).length + '（原 ' + entries(a).length + '）');
    fs.closeSync(b.fd);
    return;
  }

  if (cmd === 'verify') {
    const a = readAsar(argv[1]);
    const b = argv[2] ? readAsar(argv[2]) : null;
    const list = entries(a);
    let bad = 0;
    let skipped = 0;
    for (const e of list) {
      // 外部(unpacked)文件不在 asar 里，重打包时原样不动，这里跳过
      if (e.node.unpacked) { skipped++; continue; }
      let got;
      try { got = readEntry(a, e.node, e.path); }
      catch (err) { console.log('读取失败 ' + e.path + ': ' + err.message); bad++; continue; }
      if (got.length !== e.node.size) { console.log('长度不符 ' + e.path + ' ' + got.length + ' != ' + e.node.size); bad++; continue; }
      if (e.node.integrity && e.node.integrity.hash) {
        const h = e.node.integrity.hash;
        const hex = /^[0-9a-fA-F]{64}$/.test(h);
        const gotHash = crypto.createHash('sha256').update(got).digest(hex ? 'hex' : 'base64');
        if (gotHash !== h) { console.log('integrity 不符 ' + e.path); bad++; }
      }
      if (b) {
        const nb = lookup(b, e.path);
        if (!nb) { console.log('对照 asar 缺少 ' + e.path); bad++; continue; }
        if (!got.equals(readEntry(b, nb, e.path))) { console.log('内容不同 ' + e.path); bad++; }
      }
    }
    console.log('校验完成：' + (list.length - skipped) + ' 个文件，问题 ' + bad + ' 个（跳过外部文件 ' + skipped + ' 个）');
    fs.closeSync(a.fd); if (b) fs.closeSync(b.fd);
    return;
  }

  if (cmd === 'find') {
    const a = readAsar(argv[1]);
    const pattern = argv[2];
    if (!pattern) throw new Error('需要匹配模式（正则）');
    const limArg = argv.find(x => x.startsWith('--limit='));
    const limit = limArg ? parseInt(limArg.slice(8), 10) : 50;
    const re = new RegExp(pattern, 'g');
    let hits = 0;
    for (const e of entries(a)) {
      if (e.node.unpacked) continue;
      if (!/\.(js|cjs|mjs|json)$/.test(e.path)) continue;
      if (e.node.size > 16 * 1024 * 1024) continue;
      let buf;
      try { buf = readEntry(a, e.node, e.path); } catch (err) { continue; }
      if (buf.includes(0)) continue;
      const text = buf.toString('utf8');
      const m = text.match(re);
      if (m) {
        console.log(e.path + '  ' + m.length + ' 处');
        if (++hits >= limit) break;
      }
    }
    console.log('--- 命中 ' + hits + ' 个文件');
    fs.closeSync(a.fd);
    return;
  }

  if (cmd === 'has') {
    const a = readAsar(argv[1]);
    const node = lookup(a, argv[2]);
    console.log(node ? ('有 ' + argv[2]) : ('没有 ' + argv[2]));
    fs.closeSync(a.fd);
    if (!node) process.exit(2);
    return;
  }

  if (cmd === 'extractall') {
    // 把整个 asar 摊开成一个普通目录，unpacked 的文件按其内部路径放好。
    // 用于 OnlyLoadAppFromAsar=OFF 的场景：直接以 resources\app\ 目录加载，绕过 asar。
    const a = readAsar(argv[1]);
    const outRoot = argv[2];
    const list = entries(a);
    let files = 0, unps = 0, bytes = 0;
    for (const e of list) {
      const dst = path.join(outRoot, e.path.split('/').join(path.sep));
      fs.mkdirSync(path.dirname(dst), { recursive: true });
      let buf;
      if (e.node.unpacked) {
        const unp = a.file + '.unpacked' + path.sep + e.path.split('/').join(path.sep);
        buf = fs.readFileSync(unp);
        unps++;
      } else { buf = readEntry(a, e.node, e.path); }
      fs.writeFileSync(dst, buf);
      files++; bytes += buf.length;
    }
    console.log('已展开 ' + files + ' 个文件（其中外部 ' + unps + ' 个），共 ' + (bytes / 1048576).toFixed(1) + ' MB -> ' + outRoot);
    fs.closeSync(a.fd);
    return;
  }

  if (cmd === 'unpacked') {
    // 列出 unpacked 条目（摊开目录时要特别注意它们）
    const a = readAsar(argv[1]);
    const list = entries(a).filter(e => e.node.unpacked);
    list.slice(0, 200).forEach(e => console.log(e.path));
    console.log('--- 共 ' + list.length + ' 个外部文件');
    fs.closeSync(a.fd);
    return;
  }

  if (cmd === 'fuses') {
    const info = readFuses(argv[1]);
    console.log('sentinel @ ' + info.sentinelOffset + '  schema v' + info.schemaVersion + '  count=' + info.count);
    info.rows.forEach(r => console.log('  [' + r.index + '] ' + (r.state + '   ').slice(0, 5) + r.name + '   (byte @' + r.byteOffset + ')'));
    const sets = argv.slice(2);
    if (sets.length) {
      for (const s of sets) {
        const m = /^(.+?)=([01])$/.exec(s);
        if (!m) throw new Error('格式应为 name=0|1：' + s);
        const row = info.rows.find(r => r.name === m[1]);
        if (!row) throw new Error('没有这个 fuse：' + m[1]);
        info.buffer[row.byteOffset] = m[2].charCodeAt(0);
        console.log('  已改 ' + row.name + ' -> ' + (m[2] === '1' ? 'ON' : 'OFF'));
      }
      fs.writeFileSync(argv[1], info.buffer);
      console.log('已写回 ' + argv[1] + '（注意：Authenticode 签名会因此失效）');
    }
    return;
  }

  console.log(fs.readFileSync(__filename, 'utf8').split('*')[1].trim());
}

if (require.main === module) {
  try { main(); } catch (e) { console.error('错误：' + e.message); process.exit(1); }
}
module.exports = { readAsar, writeAsar, entries, lookup, readEntry, readFuses, FUSE_NAMES };
