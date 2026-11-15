/**
 * 生成 Astra 的 1024×1024 源图标（无第三方依赖）。
 * 之后由 `tauri icon` 生成各平台所需的 PNG / ICO / ICNS。
 */
import { deflateSync } from 'node:zlib'
import { mkdirSync, writeFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const SIZE = 1024
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const out = resolve(root, 'src-tauri/icons/source.png')

const crcTable = new Uint32Array(256)
for (let n = 0; n < 256; n++) {
  let c = n
  for (let k = 0; k < 8; k++) {
    c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1
  }
  crcTable[n] = c >>> 0
}

const crc32 = (buffer) => {
  let c = 0xffffffff
  for (const byte of buffer) {
    c = crcTable[(c ^ byte) & 0xff] ^ (c >>> 8)
  }
  return (c ^ 0xffffffff) >>> 0
}

const chunk = (type, data) => {
  const typeBuffer = Buffer.from(type, 'ascii')
  const length = Buffer.alloc(4)
  length.writeUInt32BE(data.length, 0)
  const crc = Buffer.alloc(4)
  crc.writeUInt32BE(crc32(Buffer.concat([typeBuffer, data])), 0)
  return Buffer.concat([length, typeBuffer, data, crc])
}

const clamp = (value, min, max) => Math.min(max, Math.max(min, value))
const smoothstep = (edge0, edge1, value) => {
  const t = clamp((value - edge0) / (edge1 - edge0), 0, 1)
  return t * t * (3 - 2 * t)
}

/** 点到线段的距离 */
const segmentDistance = (px, py, ax, ay, bx, by) => {
  const dx = bx - ax
  const dy = by - ay
  const lengthSq = dx * dx + dy * dy
  const t = lengthSq === 0 ? 0 : clamp(((px - ax) * dx + (py - ay) * dy) / lengthSq, 0, 1)
  const x = ax + t * dx
  const y = ay + t * dy
  return Math.hypot(px - x, py - y)
}

const roundedRectSdf = (x, y) => {
  const margin = 52
  const radius = 232
  const half = SIZE / 2 - margin
  const qx = Math.abs(x - SIZE / 2) - (half - radius)
  const qy = Math.abs(y - SIZE / 2) - (half - radius)
  const outside = Math.hypot(Math.max(qx, 0), Math.max(qy, 0))
  const inside = Math.min(Math.max(qx, qy), 0)
  return outside + inside - radius
}

const raw = Buffer.alloc(SIZE * (SIZE * 4 + 1))
let offset = 0
for (let y = 0; y < SIZE; y++) {
  raw[offset++] = 0
  for (let x = 0; x < SIZE; x++) {
    const sdf = roundedRectSdf(x, y)
    const coverage = 1 - smoothstep(-1.5, 1.5, sdf)
    const t = clamp((x + y) / (SIZE * 2), 0, 1)
    let r = Math.round(79 + (168 - 79) * t)
    let g = Math.round(70 + (85 - 70) * t)
    let b = Math.round(229 + (247 - 229) * t)
    // 顶部轻微高光
    const glow = Math.max(0, 1 - Math.hypot(x - 340, y - 260) / 700) * 0.12
    r = Math.round(r + (255 - r) * glow)
    g = Math.round(g + (255 - g) * glow)
    b = Math.round(b + (255 - b) * glow)

    const stroke = 34
    const distance = Math.min(
      segmentDistance(x, y, 300, 760, 512, 250),
      segmentDistance(x, y, 512, 250, 724, 760),
      segmentDistance(x, y, 398, 596, 626, 596)
    )
    const letter = 1 - smoothstep(stroke - 1.5, stroke + 1.5, distance)
    // 右上角小星点
    const spark = 1 - smoothstep(26, 30, Math.hypot(x - 760, y - 260))
    const white = Math.max(letter, spark)
    r = Math.round(r + (255 - r) * white)
    g = Math.round(g + (255 - g) * white)
    b = Math.round(b + (255 - b) * white)

    raw[offset++] = r
    raw[offset++] = g
    raw[offset++] = b
    raw[offset++] = Math.round(255 * coverage)
  }
}

const ihdr = Buffer.alloc(13)
ihdr.writeUInt32BE(SIZE, 0)
ihdr.writeUInt32BE(SIZE, 4)
ihdr[8] = 8
ihdr[9] = 6
ihdr[10] = 0
ihdr[11] = 0
ihdr[12] = 0

const png = Buffer.concat([
  Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
  chunk('IHDR', ihdr),
  chunk('IDAT', deflateSync(raw, { level: 9 })),
  chunk('IEND', Buffer.alloc(0)),
])

mkdirSync(dirname(out), { recursive: true })
writeFileSync(out, png)
console.log(`Wrote ${out}`)
