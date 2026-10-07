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

import std.database.sql.*
import mariadb.connection.*

class TransactionImpl <: Transaction {
    
    private var transaction: MariaTransaction

    private var isolationLevel: TransactionIsoLevel

    private var accessPower: TransactionAccessMode = ReadWrite

    public init(transaction: MariaTransaction) {
        this.transaction = transaction
        this.accessPower = ReadWrite
        this.isolationLevel = RepeatableRead
        match (transaction.getTransactionIsolation()) {
            case "READ-UNCOMMITTED" => 
                this.isolationLevel = ReadUncommitted
            case "READ-COMMITTED" => 
                this.isolationLevel = ReadCommitted
            case "REPEATABLE-READ" => 
                this.isolationLevel = RepeatableRead
            case "SERIALIZABLE" => 
                this.isolationLevel = Serializable
            case _ => throw SqlException("Unknown transaction isolation level")
        }
        match(transaction.isReadOnly()) {
            case true => 
                this.accessPower = ReadOnly
            case false => 
                this.accessPower = ReadWrite
        } 
    }

    public mut override prop isoLevel: TransactionIsoLevel {
        get() {
            return isolationLevel
        }
        set(value) {
            checkResource()
            if (value != isolationLevel) {
                synchronized(connectionMutex()) {
                    let level = match (value) {
                        case ReadUncommitted => "READ-UNCOMMITTED"
                        case ReadCommitted => "READ-COMMITTED"
                        case RepeatableRead => "REPEATABLE-READ"
                        case Serializable => "SERIALIZABLE"
                        case Unspecified => "REPEATABLE-READ"
                        case _ => throw UnsupportedException()
                    }
                    transaction.setTransactionIsolation(level)
                    this.isolationLevel = value
                }
            }
        }
    }

    public mut override prop accessMode: TransactionAccessMode {
        get() {
            return accessPower
        }
        set(value) {
            checkResource()
            synchronized(connectionMutex()) {
                if(value != accessMode){
                    match(value){
                        case ReadWrite => transaction.setReadOnly(false)
                        case ReadOnly =>  transaction.setReadOnly(true)
                        case Unspecified => transaction.setReadOnly(false)
                    }
                    accessPower = value
                }
            }
        }
    }

    public mut override prop deferrableMode: TransactionDeferrableMode {
        get() {
            throw UnsupportedException()
        }
        set(_) {
            throw UnsupportedException()
        }
    }

    public override func begin(): Unit {
        checkResource()
        transaction.begin()
    }

    public override func commit(): Unit {
        checkResource()
        transaction.commit()
    }

    public override func rollback(): Unit {
        checkResource()
        transaction.rollback()
    }

    public override func save(savePointName: String): Unit {
        checkResource()
        transaction.setSavepoint(savePointName)
    }

    public override func rollback(savePointName: String): Unit {
        checkResource()
        transaction.rollback(savePointName)
    }

    public override func release(savePointName: String): Unit {
        checkResource()
        transaction.releaseSavepoint(savePointName)
    }

    private func connectionMutex() {
        transaction.connection.connectionMutex
    }

    private func checkResource(){
        if(transaction.connection.isClosed()) {
            throw SqlException("The database Connection has been closed")
        }
    }
}
