package qingzhou

import std.collection.*
import std.time.*
import stdx.encoding.json.*

/*
 * SPDX-License-Identifier: MIT
 *
 * health check middleware (K8s-style liveness + readiness).
 *
 * Copyright (c) 2026 guowei
 * BIT Foundational Software And Systems Lab
 *
 * Two flavours of health endpoint:
 *
 *   liveness  (default GET /healthz) -- "is the process itself alive?"
 *     Always answers 200 UP without touching any dependency. Liveness
 *     drives container restarts: if it probed the database, a DB
 *     outage would restart every pod in the fleet (restart storm)
 *     instead of just pulling the service out of rotation.
 *
 *   readiness (default GET /health)  -- "can we serve traffic right now?"
 *     Runs every registered probe; all pass -> 200 UP, any failure or
 *     thrown exception -> 503 DOWN with a per-check report. Point K8s
 *     readinessProbe and load-balancer health checks here.
 *
 * Probes are named lambdas returning Bool; a probe that throws is
 * reported DOWN with the exception message (never a 500 from the
 * endpoint itself).
 *
 * Responses carry Cache-Control: no-store so intermediaries never
 * cache a stale health verdict.
 *
 * Typical usage:
 *   app.use(healthCheckWith(
 *       HealthCheckOptions()
 *           .addCheck("db", { => pool.idleCount() >= 0 })
 *           .addCheck("cache", { => cache.ping() })))
 *
 * Non-GET/HEAD requests to a health path get 405 + Allow. HEAD gets
 * status and headers only (no body -- see docs/CAVEATS.md on HEAD
 * Content-Length). Requests to any other path pass through to next().
 */

/* A single named probe. `probe` returning true means healthy. */
public class HealthCheck {
    public let name: String
    public let probe: () -> Bool

    public init(name: String, probe: () -> Bool) {
        this.name = name
        this.probe = probe
    }
}

/* Outcome of running one probe: ok=false + error message when it threw. */
public class HealthProbeResult {
    public let name: String
    public let ok: Bool
    public let error: ?String

    public init(name: String, ok: Bool, error!: ?String = None) {
        this.name = name
        this.ok = ok
        this.error = error
    }
}

/*
 * Configuration for healthCheckWith().
 *   path         readiness endpoint (runs all probes)
 *   livenessPath liveness endpoint (cheap always-UP); "" disables it
 * addCheck is chainable; checks added after healthCheckWith() are
 * still honoured (options are captured by reference).
 */
public class HealthCheckOptions {
    public var path: String = "/health"
    public var livenessPath: String = "/healthz"
    private let checks: ArrayList<HealthCheck> = ArrayList<HealthCheck>()

    public init() {}

    public func addCheck(name: String, probe: () -> Bool): HealthCheckOptions {
        checks.add(HealthCheck(name, probe))
        return this
    }

    /* Registered probes, in registration order. */
    public func allChecks(): ArrayList<HealthCheck> {
        return checks
    }
}

/* Run one probe with exception capture: a throwing probe becomes a
 * DOWN result carrying the exception message, not a 500. */
public func runHealthProbe(c: HealthCheck): HealthProbeResult {
    var ok = false
    var err: ?String = None
    try {
        ok = c.probe()
    } catch (e: Exception) {
        ok = false
        err = Some(e.message)
    }
    return HealthProbeResult(c.name, ok, error: err)
}

/* Build the readiness report JSON: overall status, process uptime and
 * a per-check array. Public so custom renderers / tests can reuse it. */
public func healthReportJson(results: ArrayList<HealthProbeResult>, uptimeMs: Int64): String {
    let arr = JsonArray()
    var allUp = true
    for (r in results) {
        let o = JsonObject()
        o.put("name", JsonString(r.name))
        o.put("status", JsonString(if (r.ok) { "UP" } else { "DOWN" }))
        match (r.error) {
            case Some(e) => o.put("error", JsonString(e))
            case None => ()
        }
        arr.add(o)
        if (!r.ok) {
            allUp = false
        }
    }
    let b = JsonBuilder()
    b.put("status", if (allUp) { "UP" } else { "DOWN" })
     .putInt("uptimeMs", uptimeMs)
     .putArray("checks", arr)
    return b.build()
}

/* 200 when every probe passed, 503 otherwise. */
public func healthStatusCode(results: ArrayList<HealthProbeResult>): Int64 {
    for (r in results) {
        if (!r.ok) {
            return 503
        }
    }
    return 200
}

public func healthCheck(): Middleware {
    return healthCheckWith(HealthCheckOptions())
}

public func healthCheckWith(opts: HealthCheckOptions): Middleware {
    // Process start captured at middleware construction time; the
    // readiness report uses it to expose uptimeMs.
    let started = MonoTime.now()
    return { ctx: Context, next: () -> Unit =>
        let p = ctx.path()
        let m = ctx.method()
        let isLiveness = opts.livenessPath.size > 0 && p == opts.livenessPath
        let isReadiness = p == opts.path
        if (!isLiveness && !isReadiness) {
            next()
            return ()
        }
        // Health endpoints answer GET (K8s probes) and HEAD (LB
        // lightweight checks); anything else is a client error.
        if (m != "GET" && m != "HEAD") {
            ctx.status(405).header("allow", "GET, HEAD")
            return ()
        }
        if (m == "HEAD") {
            // Status + headers only: committing a body would set a
            // non-zero Content-Length without a body on the wire.
            ctx.status(if (isLiveness) { 200 } else { 503 })
                .header("cache-control", "no-store")
            return ()
        }
        if (isLiveness) {
            // No probes here on purpose -- see the header comment.
            ctx.status(200)
                .header("cache-control", "no-store")
                .json("{\"status\":\"UP\"}")
            return ()
        }
        // readiness: run every probe, then report.
        let results = ArrayList<HealthProbeResult>()
        for (c in opts.allChecks()) {
            results.add(runHealthProbe(c))
        }
        let code = healthStatusCode(results)
        let uptime = (MonoTime.now() - started).toMilliseconds()
        ctx.status(code)
            .header("cache-control", "no-store")
            .json(healthReportJson(results, uptime))
    }
}
