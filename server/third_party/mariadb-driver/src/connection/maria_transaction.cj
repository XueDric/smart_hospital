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
protected package mariadb.connection

protected class MariaTransaction {

    private static const CLOSE_AUTO_COMMIT = "SET SESSION autocommit = 0"

    private static const OPEN_AUTO_COMMIT = "SET SESSION autocommit = 1"

    private static const QUERY_AUTO_COMMIT = "SELECT @@autocommit"

    private static const QUERY_ISO_LEVEL_SQL = "SELECT @@transaction_isolation"

    private static const QUERY_ACCESS_MODE_SQL = "SELECT @@transaction_read_only"

    private static const START_TRANSACTION_SQL = "BEGIN"

    private static const COMMIT_TRANSACTION_SQL = "COMMIT"

    private static const ROLLBACK_TRANSACTION_SQL = "ROLLBACK"

    private static const SAVE_TRANSACTION_SQL = "SAVEPOINT"

    private static const ROLLBACK_TO_SAVEPOINT_SQL = "ROLLBACK TO"

    private static const RELEASE_SAVEPOINT_SQL = "RELEASE SAVEPOINT"

    private static const CHANGE_TO_READ_UNCOMMITED_SQL = "SET SESSION transaction_isolation = 'READ-UNCOMMITTED'"

    private static const CHANGE_TO_READ_COMMITED_SQL = "SET SESSION transaction_isolation = 'READ-COMMITTED'"

    private static const CHANGE_TO_REPEATABLE_READ_SQL = "SET SESSION transaction_isolation = 'REPEATABLE-READ'"

    private static const CHANGE_TO_READ_SERIALIZABLE_SQL = "SET SESSION transaction_isolation = 'SERIALIZABLE'"

    private static const CHANGE_TO_READ_WRITE_SQL = "SET SESSION transaction_read_only = OFF"

    private static const CHANGE_TO_READ_ONLY_SQL = "SET SESSION transaction_read_only = ON"

    protected let connection: MariaConnection

    protected init(connection: MariaConnection) {
        this.connection = connection
    }

    protected func getAutoCommit(): Bool {
        let result = connection.sendQuery(QUERY_AUTO_COMMIT)
        if (!result.next()) {
            throw ResponseErrorException("Query transaction isolation level failed")
        }
        let autoCommit: String = result.getString(1).getOrThrow()
        match (autoCommit) {
            case "0" => false
            case "1" => true
            case value => throw ResponseErrorException("Unknown transaction isolation level ${value}")
        }
    }

    protected func setAutoCommit(autoCommit: Bool): Unit {
        let changeAutoCommit = match (autoCommit) {
            case true => OPEN_AUTO_COMMIT
            case false => CLOSE_AUTO_COMMIT
        }
        connection.sendCommand(changeAutoCommit)
    }

    public func getTransactionIsolation(): String {
        let result = connection.sendQuery(QUERY_ISO_LEVEL_SQL)
        if (!result.next()) {
            throw ResponseErrorException("Query transaction isolation level failed")
        }
        return result.getString(1).getOrThrow()
    }

    public func setTransactionIsolation(level: String): Unit {
        let changeIsoLevel = match (level) {
            case "READ-UNCOMMITTED" => CHANGE_TO_READ_UNCOMMITED_SQL
            case "READ-COMMITTED" => CHANGE_TO_READ_COMMITED_SQL
            case "REPEATABLE-READ" => CHANGE_TO_REPEATABLE_READ_SQL
            case "SERIALIZABLE" => CHANGE_TO_READ_SERIALIZABLE_SQL
            case _ => throw IllegalArgumentException("Unkonw isolation level: ${level}")
        }
        connection.sendCommand(changeIsoLevel)
    }

    public func begin(): Unit {
        connection.sendCommand(START_TRANSACTION_SQL)
    }

    public func commit(): Unit {
        connection.sendCommand(COMMIT_TRANSACTION_SQL)
    }

    public func rollback(): Unit {
        connection.sendCommand(ROLLBACK_TRANSACTION_SQL)
    }

    public func setSavepoint(name: String): Unit {
        connection.sendCommand("${SAVE_TRANSACTION_SQL} ${name}")
    }

    public func rollback(name: String): Unit {
        connection.sendCommand("${ROLLBACK_TO_SAVEPOINT_SQL} ${name}")
    }

    public func releaseSavepoint(name: String): Unit {
        connection.sendCommand("${RELEASE_SAVEPOINT_SQL} ${name}")
    }

    public func setReadOnly(readOnly: Bool): Unit {
        let changeAccessMode = match (readOnly) {
            case false => CHANGE_TO_READ_WRITE_SQL
            case true => CHANGE_TO_READ_ONLY_SQL
        }
        connection.sendCommand(changeAccessMode)
    }

    public func isReadOnly(): Bool {
        let result = connection.sendQuery(QUERY_ACCESS_MODE_SQL)
        if (!result.next()) {
            throw ResponseErrorException("Query transaction isolation level failed")
        }
        let accessMode: String = result.getString(1).getOrThrow()
        match (accessMode) {
            case "0" => false
            case "1" => true
            case _ => throw ResponseErrorException("Unkonw transaction access mode")
        }
    }
}