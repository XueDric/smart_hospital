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

import std.collection.*
import std.database.sql.*
import std.io.*
import std.time.*
import std.math.numeric.*
import mariadb.connection.*

public class QueryResultImpl <: QueryResult {
    
    private var infos: Array<ColumnInfo>

    private var result: ResultSet

    private var closed: Bool

    public override prop columnInfos: Array<ColumnInfo> {
        get() {
            return infos
        }
    }

    protected QueryResultImpl(result: ResultSet) {
        this.result = result
        let arrayList = ArrayList<ColumnInfo>()
        for (i in result.columnDefinitions) {
            let info = ColumnInfoImpl(i)
            arrayList.add(info)
        }
        this.infos = arrayList.toArray()
        closed = false
    }

    public func next(): Bool {
        return result.next()
    }

    public func get<T>(index: Int): T {
        return getOrNull<T>(index) ?? throw NoneValueException()
    }

    public func getOrNull<T>(index: Int): ?T {
        checkResource()
        if (index <= 0) {
            throw IllegalArgumentException("The index must be greater than 0")
        }
        let instance: ?T = None
        //var value: Any
        let value = 
        match (instance) {
            case v: ?Bool => result.getBool(index)
            case v: ?Int8 => result.getInt8(index)
            case v: ?Int16 => result.getInt16(index)
            case v: ?Int32 => result.getInt32(index)
            case v: ?Int64 => result.getInt64(index)
            case v: ?UInt8 => result.getUInt8(index)
            case v: ?UInt16 => result.getUInt16(index)
            case v: ?UInt32 => result.getUInt32(index)
            case v: ?UInt64 => result.getUInt64(index)
            case v: ?Float16 => result.getFloat16(index)
            case v: ?Float32 => result.getFloat32(index)
            case v: ?Float64 => result.getFloat64(index)
            case v: ?String => result.getString(index)
            case v: ?Array<Byte> => result.getArray(index)
            case v: ?InputStream => result.getInputStream(index)
            case v: ?DateTime => result.getDateTime(index)
            case v: ?BigInt => result.getBigInt(index)
            case v: ?Decimal => result.getDecimal(index)
            case _ => throw UnsupportedException("unsupport type")
        }
        return (value as ?T) ?? throw IllegalStateException()
    }

    @Deprecated
    public override func next(_: Array<SqlDbType>): Bool {
        throw UnsupportedException("Deprecated method")
    }

    public override func close() {
        checkResource()
        closed = true
    }

    public override func isClosed(): Bool {
        return closed
    }

    private func checkResource() {
        if (isClosed()) {
            throw SqlException("The database Connection has been closed")
        }
    }
}
