/**
 * 刚发送/刚生成的 Blob 在写入 IndexedDB 前也可能被请求用到（图片内联、生图导出）。
 * 以附件本地 id 为 key 的内存缓存，读取时优先命中，未命中再读 IndexedDB。
 */
const blobs = new Map<string, Blob>()

export const cacheBlob = (id: string, blob: Blob) => {
  blobs.set(id, blob)
}

export const getCachedBlob = (id: string): Blob | undefined => blobs.get(id)

export const releaseCachedBlob = (id: string) => {
  blobs.delete(id)
}
