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

import std.sync.*
import std.collection.*
import std.database.sql.*
import mariadb.connection.*

public class ConnectionImpl <: Connection {

    private var currentState: ConnectionState

    private var connection: MariaConnection

    private var transaction: Transaction

    private var options: Map<String, String>

    public override prop state: ConnectionState {
        get() {
            return currentState
        }
    }

    public ConnectionImpl(options: Map<String, String>) {
        this.currentState = ConnectionState.Connecting
        this.options = options
        try {
            this.connection = createAuthedConnection(options)
        } catch (e: ConnectFailedException) {
            currentState = ConnectionState.Broken
            throw e
        }
        this.transaction = TransactionImpl(connection.createTransaction())
        this.currentState = ConnectionState.Connected
    }

    public override func getMetaData(): Map<String, String> {
        checkResource()
        return options
    }

    public override func prepareStatement(sql: String): Statement {
        checkResource()
        checkEmptySql(sql)
        if (let Some(mode) <- options.get(Params.PrepareMode)) {
            match (mode) {
                case "server" => return ServerPrepareStatement(sql, this)
                case "client" => return ClientPrepareStatement(sql, this)
                case other => throw ConnectFailedException("Unknow prepare.mode value: ${other}")
            }
        }
        return ServerPrepareStatement(sql, this)
    }

    public override func createTransaction(): Transaction {
        checkResource()
        return transaction
    }

    public override func close() {
        checkResource()
        synchronized(getConnectionMutex()) {
            currentState = ConnectionState.Closed
            connection.close()
        }
    }

    public override func isClosed(): Bool {
        return connection.isClosed()
    }

    protected func sendCommand(sql: String) {
        try {
            return connection.sendCommand(sql)
        } catch (e: ResponseErrorException) {
            throw SqlException(e.message)
        }
    }

    protected func sendQuery(sql: String): ResultSet {
        try {
            return connection.sendQuery(sql)
        } catch (e: ResponseErrorException) {
            throw SqlException(e.message)
        }
    }

    protected func sendUpdate(sql: String): ChangeResult {
        try {
            return connection.sendUpdate(sql)
        } catch (e: ResponseErrorException) {
            throw SqlException(e.message)
        }
    }

    protected func sendPrepare(sql: String): PrepareResult {
        try {
            return connection.sendPrepare(sql)
        } catch (e: ResponseErrorException) {
            throw SqlException(e.message)
        }
    }

    protected func executeQueryPrepare(prepare: PrepareResult, params: Array<Any>): ResultSet {
        try {
            return connection.executeQueryPrepare(prepare.id, params)
        } catch (e: ResponseErrorException) {
            throw SqlException(e.message)
        }
    }

    protected func executeQueryPrepareWithCursor(prepare: PrepareResult, params: Array<Any>, fetchSize: UInt32): ResultSet {
        try {
            return connection.executeQueryPrepareWithCursor(prepare.id, params, fetchSize)
        } catch (e: ResponseErrorException) {
            throw SqlException(e.message)
        }
    }

    protected func executeUpdatePrepare(prepare: PrepareResult, params: Array<Any>): ChangeResult {
        try {
            return connection.executeUpdatePrepare(prepare, params)
        } catch (e: ResponseErrorException) {
            throw SqlException(e.message)
        }
    }

    protected func closePrepare(id: UInt32) {
        return connection.closePrepare(id)
    }

    protected func getConnectionMutex(): Mutex {
        return connection.connectionMutex
    }

    private func checkEmptySql(sql: String) {
        if (sql.size == 0) {
            throw SqlException("Empty SQL")
        }
    }

    private func checkResource() {
        if (isClosed()) {
            throw SqlException("The database Connection has been closed")
        }
    }
}
