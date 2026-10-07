package qingzhou

import std.collection.*

/*
 * SPDX-License-Identifier: MIT
 *
 * lightweight configuration.
 *
 * Copyright (c) 2026 guowei
 * BIT Foundational Software And Systems Lab
 *
 * A Config is an in-memory string key/value bag with typed accessors.
 * It can be populated from a key=value file (.env style) via
 * loadConfigFile(), or built up programmatically via set().
 *
 * NOTE on environment variables: Cangjie 1.0.5 std does not expose
 * getEnv / envVars (verified: neither std.env nor std.process has them
 * on this toolchain). So environment-driven config is out of scope here;
 * load from a file, from command-line args, or via CFFI if you need the
 * process environment.
 */
public class Config {
    private let map: HashMap<String, String> = HashMap<String, String>()

    public init() {}

    /* Raw string access. */
    public func get(key: String): ?String {
        return map.get(key)
    }

    public func getOr(key: String, default_: String): String {
        match (map.get(key)) {
            case Some(v) => v
            case None => default_
        }
    }

    /* Typed accessors (reuse util.cj parsers). */
    public func getInt(key: String): ?Int64 {
        match (map.get(key)) {
            case Some(v) => parseInt64OrNone(v)
            case None => None
        }
    }

    public func getIntOr(key: String, default_: Int64): Int64 {
        match (getInt(key)) {
            case Some(n) => n
            case None => default_
        }
    }

    public func getFloat(key: String): ?Float64 {
        match (map.get(key)) {
            case Some(v) => parseFloat64OrNone(v)
            case None => None
        }
    }

    public func getBool(key: String): ?Bool {
        match (map.get(key)) {
            case Some(v) => parseBoolOrNone(v)
            case None => None
        }
    }

    public func getBoolOr(key: String, default_: Bool): Bool {
        match (getBool(key)) {
            case Some(b) => b
            case None => default_
        }
    }

    /* Mutation + inspection. */
    public func set(key: String, value: String): Unit {
        map[key] = value
    }

    public func has(key: String): Bool {
        match (map.get(key)) {
            case Some(_) => true
            case None => false
        }
    }

    public func size(): Int64 {
        return map.size
    }
}

/*
 * Load a Config from a key=value file (.env style).
 *
 *   - one "key=value" per line
 *   - lines starting with '#' are comments (skipped)
 *   - blank lines are skipped
 *   - values may contain '=' (split on the FIRST '=' only)
 *   - surrounding whitespace on key/value is trimmed
 *   - a missing/unreadable file yields an empty Config (no throw)
 *
 * Windows CRLF is handled by stripping a trailing '\r' before parsing.
 */
public func loadConfigFile(path: String): Config {
    match (readFileBytes(path)) {
        case Some(bytes) =>
            return parseConfigText(String.fromUtf8(bytes))
        case None => ()
    }
    return Config()
}

/*
 * Parse a key=value config text (pure logic, no file IO) into a Config.
 * This is the testable core of loadConfigFile():
 *
 *   - one "key=value" per line
 *   - '#' comments and blank lines are skipped
 *   - values may contain '=' (split on the FIRST '=' only)
 *   - surrounding whitespace on key/value is trimmed
 *   - Windows CRLF is tolerated (trailing '\r' stripped per line)
 */
public func parseConfigText(text: String): Config {
    let c = Config()
    let lines = text.split("\n", -1, removeEmpty: false)
    for (rawLine in lines) {
        let line = stripTrailingCR(rawLine)
        let trimmed = line.trimAscii()
        if (trimmed.size == 0 || trimmed[0] == UInt8(0x23)) {
            // empty or '#' comment
            continue
        }
        match (trimmed.indexOf("=")) {
            case Some(idx) =>
                let key = trimmed[0..idx].trimAscii()
                let value = trimmed[idx + 1..].trimAscii()
                if (key.size > 0) {
                    c.set(key, value)
                }
            case None => ()  // line without '=' -> ignore
        }
    }
    return c
}

/*
 * Strip a single trailing carriage-return from a line (Windows CRLF
 * tolerance). Returns the input unchanged when there is no trailing CR.
 */
func stripTrailingCR(s: String): String {
    if (s.size > 0 && s[s.size - 1] == UInt8(0x0D)) {
        return s[0..(s.size - 1)]
    }
    return s
}
