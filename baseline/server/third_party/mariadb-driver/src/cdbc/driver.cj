/*
 * Copyright (C) 2024 Yesokim
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
package mariadb.cdbc

import std.convert.*
import std.database.sql.*
import stdx.encoding.url.*
import mariadb.connection.*

let _ = DriverManager.register("mariadb", MariaDBDriver())

public class MariaDBDriver <: Driver {

    private let driverName: String = "MariaDBDriver"

    private let driverVersion: String = "1.0.0"

    private let supportPooling: Bool = true

    protected init() {
    }

    public override prop name: String {
        get() {
            return driverName
        }
    }

    public override prop version: String {
        get() {
            return driverVersion
        }
    }

    public override prop preferredPooling: Bool {
        get() {
            return supportPooling
        }
    }

    public override func open(url: String, opts: Array<(String, String)>): Datasource {
        let parsed = URL.parse(url)
        if (parsed.scheme != "mariadb") {
            throw IllegalArgumentException("Bad connection url")
        }
        let host = parsed.hostName
        let port = parsed.port
        let datasource = PooledDatasource(DatasourceImpl())
        if (host.size > 0) {
            datasource.setOption(Params.Host, host)
        }
        if (port.size > 0) {
            datasource.setOption(Params.Port, port)
        }

        let database = parsed.path.removePrefix("/")
        if (database.size > 0) {
            datasource.setOption(Params.Database, database)
        }

        if (let Some(value) <- parsed.query) {
            let splited = value.split("&", removeEmpty: true)
            for (item in splited) {
                let tuple = item.split("=", removeEmpty: true)
                if (tuple.size != 2) {
                    throw IllegalArgumentException("Illegal agrument: ${item}")
                }
                datasource.setOption(tuple[0], tuple[1])
            }
        }
        let username = parsed.userInfo.username()
        if (username.size > 0) {
            datasource.setOption(Params.Username, username)
        }
        let password = parsed.userInfo.password()
        if (let Some(v) <- password && v.size > 0) {
            datasource.setOption(Params.Password, v)
        }
        for ((k, v) in opts) {
            setPooledDataSourceParam(datasource, k, v)
            datasource.setOption(k, v)
        }
        return datasource
    }

    private func setPooledDataSourceParam(datasource: PooledDatasource, k: String, v: String): Unit {
        if (k == Params.PoolConnectionTimout) {
            let connnectionTimeout = Float64.tryParse(v) ?? throw IllegalArgumentException("Parse PoolConnectionTimout failed: ${v}")
            return datasource.connectionTimeout = Duration.second * connnectionTimeout
        }
        if (k == Params.PoolIdleTimout) {
            let idleTimeout = Float64.tryParse(v) ?? throw IllegalArgumentException("Parse PoolIdleTimout failed: ${v}")
            return datasource.idleTimeout = Duration.minute * idleTimeout
        }
        if (k == Params.PoolKeepaliveTime) {
            let keepaliveTime = Float64.tryParse(v) ?? throw IllegalArgumentException("Parse PoolKeepaliveTime failed: ${v}")
            return datasource.keepaliveTime = Duration.minute * keepaliveTime
        }
        if (k == Params.PoolMaxIdleSize) {
            let maxIdleSize = Int32.tryParse(v) ?? throw IllegalArgumentException("Parse PoolMaxIdleSize failed: ${v}")
            return datasource.maxIdleSize = maxIdleSize
        }
        if (k == Params.PoolMaxLifeTime) {
            let maxLifeTime = Float64.tryParse(v) ?? throw IllegalArgumentException("Parse PoolMaxLifeTime failed: ${v}")
            return datasource.maxLifeTime = Duration.minute * maxLifeTime
        }
        if (k == Params.PoolMaxSize) {
            let maxSize = Int32.tryParse(v) ?? throw IllegalArgumentException("Parse PoolMaxSize failed: ${v}")
            return datasource.maxSize = maxSize
        }
    }
}

