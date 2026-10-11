package qingzhou

import std.fs.*
import std.collection.*

/*
 * SPDX-License-Identifier: MIT
 *
 * static file serving middleware.
 *
 * Copyright (c) 2026 guowei
 * BIT Foundational Software And Systems Lab
 *
 *   app.use(serve("./public"))              // raw (no prefix)
 *   app.use(serveAt("./public", "/static")) // URL prefix + strip
 *
 *  behaviour:
 *   - GET / HEAD only; other methods pass through to next()
 *   - Resolves URL path to a file under rootDir
 *   - Blocks path traversal ("..", "\\") with 403
 *   - Sets Content-Type from extension (mime.cj)
 *   - 404 when file missing or unreadable
 *
 *  behaviour (additions):
 *   - Range request (RFC 7233) -> 206 Partial Content with
 *     Content-Range; only single-range supported in .
 *   - Multi-range and malformed Range headers are treated as
 *     "ignored" per RFC 7233 part 3.1 (the request falls through to
 *     the full-body 200).
 *   - Unsatisfiable Range (out of bounds) -> 416 with
 *     Content-Range value of the form bytes STAR/size
 *   - ETag: size-only strong validator "<size>" (quoted). Documented
 *     limitation in etag.cj (no mtime / no content hash).
 *   - If-None-Match matching -> 304 Not Modified with ETag.
 *   - HEAD requests carry Content-Length / ETag but no body, so
 *     client probes are cheap.
 *
 * The middleware itself never calls next() on a matched static request,
 * so it short-circuits the downstream chain (Koa static semantics).
 *
 * Out-of-scope (lands later if needed):
 *   - Last-Modified / If-Modified-Since: std.fs on cangjie 1.0
 *     (patch 5) does not expose file mtime. DateTime.now() is local
 *     time, and there is no UTC factory in std.time, so we can't
 *     reliably produce a GMT HTTP-date. Documented for +.
 */
public class StaticOptions {
    public var prefix: String = ""         // URL prefix to strip (e.g. "/static")
    public var indexFile: String = "index.html"  // directory -> file
    public var notFoundStatus: Int64 = 404
    public var notFoundBody: String = "{\"error\":\"Not Found\"}"
    public var forbiddenStatus: Int64 = 403
    public var forbiddenBody: String = "{\"error\":\"Forbidden\"}"
    /* feature flags (defaults ON; turn off for byte-perfect ). */
    public var enableRange: Bool = true
    public var enableETag: Bool = true
    /* in-memory file cache. When true, file bytes are read once and
     * reused across requests (big win for hot static assets). Files are
     * keyed by their resolved filesystem path. A cached entry is kept for
     * the lifetime of the process; during development turn this off (or
     * restart) to pick up edits. */
    public var enableCache: Bool = true
    /* SPA history-mode fallback. When true, a request for a missing
     * file (whose path is NOT under apiPrefix) serves indexFile instead of
     * 404, so client-side routers (Vue/React history mode) can take over.
     * apiPrefix paths (e.g. /api/...) always 404 rather than fall back, so
     * a mistyped API route does not silently return the HTML shell. */
    public var spaFallback: Bool = false
    public var apiPrefix: String = "/api"

    public init() {}
    public init(p: String) {
        this.prefix = p
    }
}

/*
 * in-memory cache for served static files.
 * One instance per serveWithOpts() middleware, so different roots/prefixes
 * keep independent caches. The middleware closure captures this by let
 * reference (class holds mutable map, closure holds immutable handle),
 * sidestepping Cangjie's "mutable var captured by lambda" restriction.
 */
public class StaticCache {
    private let map: HashMap<String, Array<UInt8>> = HashMap<String, Array<UInt8>>()

    public init() {}

    public func get(path: String): ?Array<UInt8> {
        return map.get(path)
    }

    public func put(path: String, bytes: Array<UInt8>): Unit {
        map[path] = bytes
    }

    public func size(): Int64 {
        return map.size
    }
}

/*
 * Convenience constructor with default options.
 * The name `static` is reserved in Cangjie, so we use `serve` (matches
 * the Koa convention: app.use(serve("./public"))).
 */
public func serve(rootDir: String): Middleware {
    return serveWithOpts(rootDir, StaticOptions())
}

public func serveAt(rootDir: String, prefix: String): Middleware {
    return serveWithOpts(rootDir, StaticOptions(prefix))
}

public func serveWithOpts(rootDir: String, opts: StaticOptions): Middleware {
    // Normalise rootDir once at registration: strip trailing slashes so
    // we can safely concat "/<path>" without producing "//foo".
    let root: String = stripTrailingSlashes(rootDir)
    let capturedOpts: StaticOptions = opts
    // per-middleware file cache (survives across requests).
    let cache: StaticCache = StaticCache()

    return { ctx: Context, next: () -> Unit =>
        // GET / HEAD only. Other methods fall through.
        let m = ctx.method()
        if (m != "GET" && m != "HEAD") {
            next()
            return
        }

        let urlPath = ctx.path()

        // Prefix guard: when a prefix is configured, urls that don't start
        // with it must fall through to next() instead of being claimed.
        // Without a prefix (raw serve), every request is fair game.
        var relPath = urlPath
        let pfx = capturedOpts.prefix
        if (pfx.size > 0) {
            // Match requires prefix at the start of the path. We do an
            // exact == check on the prefix slice to avoid partial matches
            // like "/static2" matching "/static2.png" as "/static2".
            // The trailing boundary must be either end of string or '/'.
            if (!(relPath.size >= pfx.size && relPath[0..pfx.size] == pfx)) {
                next()
                return
            }
            relPath = relPath[pfx.size..]
            // If there's a remainder, it MUST start with '/'.
            if (relPath.size > 0 && relPath[0] != UInt8(0x2F)) {
                next()
                return
            }
        }
        if (relPath.size > 0 && relPath[0] == UInt8(0x2F)) {
            relPath = relPath[1..]
        }

        // Directory -> index file.
        if (relPath.size == 0 || relPath[relPath.size - 1] == UInt8(0x2F)) {
            relPath = relPath + capturedOpts.indexFile
        }

        // Decode %2e%2e and back-slashes: even after path traversal check
        // the URL itself has been decoded by stdx into ctx.path(). The
        // literal ".." segment is rejected below; back-slashes are also
        // rejected to avoid Windows-only surprise moves.
        if (hasTraversal(relPath)) {
            ctx.status(capturedOpts.forbiddenStatus)
                .header("content-type", "application/json")
                .body(capturedOpts.forbiddenBody)
            return
        }

        // Compose filesystem path.
        let fullPath = root + "/" + relPath

        // serve from cache when enabled + present; otherwise read from
        // disk (and populate the cache on success). A cache miss still runs
        // the same File open/read/close sequence and the same 404 on error.
        var sendBytes: Array<UInt8> = Array<UInt8>()
        if (capturedOpts.enableCache) {
            match (cache.get(fullPath)) {
                case Some(cached) =>
                    sendBytes = cached
                case None =>
                    match (readFileBytes(fullPath)) {
                        case Some(bytes) =>
                            cache.put(fullPath, bytes)
                            sendBytes = bytes
                        case None =>
                            handleMissing(root, capturedOpts, ctx)
                            return
                    }
            }
        } else {
            match (readFileBytes(fullPath)) {
                case Some(bytes) =>
                    sendBytes = bytes
                case None =>
                    handleMissing(root, capturedOpts, ctx)
                    return
            }
        }
        let mime = mimeOf(fullPath)

        /* ---------- mtime 取一次，ETag 与 Last-Modified 共用 ---------- */
        let mtime = fileLastModified(fullPath)
        let etag = match (mtime) {
            case Some(mt) =>
                if (capturedOpts.enableETag) { makeETagWithMtime(sendBytes.size, mt) } else { "" }
            case None =>
                if (capturedOpts.enableETag) { makeETag(sendBytes.size) } else { "" }
        }

        // Always advertise Accept-Ranges so clients know partial GETs work.
        ctx.header("accept-ranges", "bytes")

        /* ---------- Last-Modified + If-Modified-Since ---------- */
        let lastMod = match (mtime) {
            case Some(mt) => formatHttpDate(mt)
            case None => ""
        }
        if (lastMod.size > 0) {
            ctx.header("last-modified", lastMod)
            match (ctx.requestHeader("If-Modified-Since")) {
                case Some(ims) =>
                    if (lastModifiedMatches(ims, lastMod)) {
                        ctx.status(304).header("last-modified", lastMod)
                        return
                    }
                case None => ()
            }
        }

        // 304 path: short-circuit before deciding Range.
        if (capturedOpts.enableETag && etag.size > 0) {
            let inm = ctx.requestHeader("If-None-Match")
            match (inm) {
                case Some(v) =>
                    if (etagMatches(v, etag)) {
                        ctx.status(304)
                            .header("etag", etag)
                        // Body intentionally not set; stdx sends a 304
                        // with no body and the ETag + Accept-Ranges.
                        return
                    }
                case None => ()
            }
        }

        // Range path: parse, dispatch to 206 single / 206 multipart / 416 / fall-through.
        if (capturedOpts.enableRange) {
            let rangeHdr = ctx.requestHeader("Range")
            match (rangeHdr) {
                case Some(raw) =>
                    let res = parseRanges(raw, sendBytes.size)
                    match (res) {
                        case RangesResult.Satisfiable(specs) =>
                            if (specs.size == 1) {
                                let spec = specs[0]
                                let slice = sliceBytes(sendBytes, spec.start, spec.end)
                                ctx.status(206)
                                    .header("content-type", mime)
                                    .header("content-range", formatContentRange(spec, sendBytes.size))
                                    .header("content-length", spec.length().toString())
                                if (etag.size > 0) {
                                    ctx.header("etag", etag)
                                }
                                ctx.body(slice)
                                return
                            } else {
                                // Multi-range -> multipart/byteranges (RFC 7233 4.1)
                                let boundary = "qz" + randomHex(8)
                                let body = formatMultipartBody(specs, sendBytes, mime, boundary, sendBytes.size)
                                ctx.status(206)
                                    .header("content-type", "multipart/byteranges; boundary=" + boundary)
                                    .header("content-length", body.size.toString())
                                if (etag.size > 0) {
                                    ctx.header("etag", etag)
                                }
                                ctx.body(body)
                                return
                            }
                        case RangesResult.Unsatisfiable =>
                            ctx.status(416)
                                .header("content-type", "application/json")
                                .header("content-range", formatUnsatisfiableContentRange(sendBytes.size))
                                .body("{\"error\":\"Range Not Satisfiable\"}")
                            return
                        case RangesResult.Malformed =>
                            // Per RFC 7233 section 3.1, ignore the malformed header
                            // and serve the full resource. Fall through to 200.
                            ()
                    }
                case None => ()
            }
        }

        // Default: full body (200) for GET, headers-only for HEAD.
        ctx.status(200)
            .header("content-type", mime)
        if (etag.size > 0) {
            ctx.header("etag", etag)
        }
        if (m == "HEAD") {
            // HEAD responses MUST NOT carry a body. stdx 1.0.5 raises
            // an internal "the body should be empty" check when both
            // Content-Length (from us) and a body (even an empty one)
            // are sent on HEAD, so we skip both: no content-length
            // header, no body() call. Accept-Ranges and ETag still
            // advertise range support and the validator so HEAD can
            // be used as a cheap probe.
            let _ = Array<UInt8>(0, { _ => UInt8(0) })  // no-op body call so the branch has a value (suppresses "unused expression" warning)
        } else {
            ctx.header("content-length", sendBytes.size.toString())
            ctx.body(sendBytes)
        }
    }
}

/*
 * Handle a missing static file: either fall back to indexFile (SPA
 * history-mode routing) or emit the configured 404. Fallback only applies
 * when opts.spaFallback is on AND the request path is not under
 * opts.apiPrefix (so API routes still 404 rather than returning HTML).
 */
func handleMissing(root: String, opts: StaticOptions, ctx: Context): Unit {
    if (opts.spaFallback) {
        let p = ctx.path()
        let ap = opts.apiPrefix
        let isApi = (ap.size > 0 && p.size >= ap.size && p[0..ap.size] == ap)
        if (!isApi) {
            match (readFileBytes(root + "/" + opts.indexFile)) {
                case Some(bytes) =>
                    ctx.status(200)
                        .header("content-type", "text/html; charset=utf-8")
                        .body(bytes)
                    return
                case None => ()
            }
        }
    }
    ctx.status(opts.notFoundStatus)
        .header("content-type", "application/json")
        .body(opts.notFoundBody)
}

/*
 * read a whole file into memory. Returns None on any failure
 * (missing file, permission denied, read error). The caller maps None
 * to its chosen HTTP status (404). Reads into a size-prefixed buffer
 * and trims trailing zero-fill if read() returned fewer bytes.
 */
func readFileBytes(path: String): ?Array<UInt8> {
    let file: File
    try {
        file = File(path, Read)
    } catch (e: Exception) {
        return None
    }
    let size = file.length
    let bytes = Array<UInt8>(Int64(size), { _ => UInt8(0) })
    let readN: Int64
    try {
        readN = file.read(bytes)
    } catch (e: Exception) {
        file.close()
        return None
    }
    file.close()
    if (readN == bytes.size) {
        return Some(bytes)
    }
    return Some(Array<UInt8>(Int64(readN), { i => bytes[i] }))
}

/*
 * Take a half-open-to-closed byte slice from a backing buffer.
 * Both `start` and `end` are inclusive indices validated by parseRange.
 *
 * This allocates a fresh Array<UInt8> rather than reusing the source
 * buffer (so it stays GC-able after we close the File). The slice is
 * always at least 1 byte long (parseRange guarantees end >= start).
 */
func sliceBytes(src: Array<UInt8>, start: Int64, end: Int64): Array<UInt8> {
    let len = end - start + 1
    let out = Array<UInt8>(Int64(len), { i => src[start + i] })
    return out
}

/*
 * Detect a path-traversal attempt by scanning segments. Returns true
 * when any segment is exactly "..", or when a back-slash (Windows
 * separator) appears anywhere. We do NOT resolve symlinks (realpath
 * containment); that lands later if needed.
 */
func hasTraversal(relPath: String): Bool {
    let n = relPath.size
    var i: Int64 = 0
    var segStart: Int64 = 0
    while (i <= n) {
        let isSep = (i == n) || (relPath[i] == UInt8(0x2F))
        if (isSep) {
            let segLen = i - segStart
            if (segLen == 2 && relPath[segStart] == UInt8(0x2E) && relPath[segStart + 1] == UInt8(0x2E)) {
                return true
            }
            segStart = i + 1
        }
        if (i < n && relPath[i] == UInt8(0x5C)) {  // '\\'
            return true
        }
        i += 1
    }
    return false
}

/*
 * Strip repeated trailing '/' from a directory path. Walks the string
 * via a copy so the input remains immutable.
 */
func stripTrailingSlashes(s: String): String {
    var out: String = s
    while (out.size > 1 && out[out.size - 1] == UInt8(0x2F)) {
        out = out[0..(out.size - 1)]
    }
    return out
}