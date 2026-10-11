package qingzhou

import std.collection.*

/*
 * SPDX-License-Identifier: MIT
 *
 * MIME type lookup by file extension.
 *
 * Copyright (c) 2026 guowei
 * BIT Foundational Software And Systems Lab
 *
 * Returns the IANA media type for the extension of `path` (without the
 * leading dot). Case-insensitive (extensions are lower-cased first).
 * Unknown / no-extension paths fall back to "application/octet-stream",
 * which is the safe default for binary downloads.
 *
 * Coverage targets  minimum: images, video, audio (single-file
 * playback only), common web fonts, plain text / source code so the
 * framework can serve public/ folders for typical apps without an
 * upload pipeline.
 *
 * Lookup is a single HashMap.get on extension only, so it is O(1) and
 * safe to call per request.
 */
private let MIME_TABLE: HashMap<String, String> = buildMimeTable()

/*
 * The let above is initialised via a function call rather than a bare
 * `{ ... }()` block — Cangjie's parser treats the bare `{` as a lambda
 * opener and demands `=>`, which only fits a single expression, not
 * a multi-statement sequence with early `m[...]` writes.
 */
func buildMimeTable(): HashMap<String, String> {
    let m = HashMap<String, String>()
    /* images */
    m[".png"]  = "image/png"
    m[".jpg"]  = "image/jpeg"
    m[".jpeg"] = "image/jpeg"
    m[".gif"]  = "image/gif"
    m[".webp"] = "image/webp"
    m[".svg"]  = "image/svg+xml"
    m[".ico"]  = "image/x-icon"
    m[".bmp"]  = "image/bmp"
    m[".tiff"] = "image/tiff"
    m[".tif"]  = "image/tiff"
    /* video (single-file; Range support is ) */
    m[".mp4"]  = "video/mp4"
    m[".webm"] = "video/webm"
    m[".ogg"]  = "video/ogg"
    m[".mov"]  = "video/quicktime"
    m[".avi"]  = "video/x-msvideo"
    m[".mkv"]  = "video/x-matroska"
    m[".m4v"]  = "video/x-m4v"
    /* audio */
    m[".mp3"]  = "audio/mpeg"
    m[".wav"]  = "audio/wav"
    m[".flac"] = "audio/flac"
    m[".aac"]  = "audio/aac"
    m[".m4a"]  = "audio/x-m4a"
    m[".oga"]  = "audio/ogg"
    /* web fonts */
    m[".woff"]  = "font/woff"
    m[".woff2"] = "font/woff2"
    m[".ttf"]   = "font/ttf"
    m[".otf"]   = "font/otf"
    m[".eot"]   = "application/vnd.ms-fontobject"
    /* text / source */
    m[".html"] = "text/html; charset=utf-8"
    m[".htm"]  = "text/html; charset=utf-8"
    m[".css"]  = "text/css; charset=utf-8"
    m[".js"]   = "application/javascript; charset=utf-8"
    m[".mjs"]  = "application/javascript; charset=utf-8"
    m[".json"] = "application/json; charset=utf-8"
    m[".xml"]  = "application/xml; charset=utf-8"
    m[".txt"]  = "text/plain; charset=utf-8"
    m[".md"]   = "text/markdown; charset=utf-8"
    m[".csv"]  = "text/csv; charset=utf-8"
    m[".map"]  = "application/json; charset=utf-8"
    /* documents / archives (basic) */
    m[".pdf"]  = "application/pdf"
    m[".zip"]  = "application/zip"
    m[".gz"]   = "application/gzip"
    m[".tar"]  = "application/x-tar"
    m[".wasm"] = "application/wasm"
    /* generic binary (used for  Range demo) */
    m[".bin"]  = "application/octet-stream"
    return m
}

/*
 * Return the registered MIME type for the file at `path`, or
 * "application/octet-stream" when the extension is unknown / missing.
 *
 * `path` is accepted as-is (with directory parts intact) because only
 * the characters after the last '.' are inspected.
 */
public func mimeOf(path: String): String {
    if (path.size == 0) {
        return "application/octet-stream"
    }
    var lastDot: Int64 = -1
    var lastSlash: Int64 = -1
    var i: Int64 = 0
    let n = path.size
    while (i < n) {
        let c = path[i]
        // case-insensitive dot match
        let cLower = if (c >= UInt8(0x41) && c <= UInt8(0x5A)) {
            c + UInt8(0x20)
        } else {
            c
        }
        if (cLower == UInt8(0x2E)) {
            lastDot = i
        }
        if (cLower == UInt8(0x2F)) {
            lastSlash = i
        }
        i += 1
    }
    // No dot, or dot only in a directory part (e.g. ".gitignore"): fall back.
    if (lastDot < 0 || lastDot <= lastSlash) {
        return "application/octet-stream"
    }
    // Extension must be non-empty (".png" works, "." alone does not).
    if (lastDot == n - 1) {
        return "application/octet-stream"
    }
    let ext = path[lastDot..].toAsciiLower()
    match (MIME_TABLE.get(ext)) {
        case Some(mt) => mt
        case None => "application/octet-stream"
    }
}
