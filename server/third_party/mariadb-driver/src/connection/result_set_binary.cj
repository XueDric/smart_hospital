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

import std.io.*
import std.time.*
import std.math.numeric.*
import mariadb.protocol.*

protected class BinaryResultSet <: ResultSet {
    
    private let columns: Array<ColumnDefinition>

    private let rows: Array<BinaryResult>

    private var currentRow: Int64

    protected BinaryResultSet(columns: Array<ColumnDefinition>, rows: Array<BinaryResult>) {
        this.columns = columns
        this.rows = rows
        this.currentRow = -1
    }

    public prop columnDefinitions: Array<ColumnDefinition> {
        get() {
            columns
        }
    }

    public func next(): Bool {
        if (currentRow + 1 == rows.size) {
            return false
        } else {
            currentRow++
            return true
        }
    }

    public override func getBool(index: Int64): ?Bool {
        return Bool.fromBinary(metadata(index), rawData(index))
    }

    public override func getInt8(index: Int64): ?Int8 {
        return Int8.fromBinary(metadata(index), rawData(index))
    }

    public override func getUInt8(index: Int64): ?UInt8 {
        return UInt8.fromBinary(metadata(index), rawData(index))
    }

    public override func getInt16(index: Int64): ?Int16 {
        return Int16.fromBinary(metadata(index), rawData(index))
    }

    public override func getUInt16(index: Int64): ?UInt16 {
        return UInt16.fromBinary(metadata(index), rawData(index))
    }

    @OverflowWrapping
    public override func getInt32(index: Int64): ?Int32 {
        return Int32.fromBinary(metadata(index), rawData(index))
    }

    public override func getUInt32(index: Int64): ?UInt32 {
        return UInt32.fromBinary(metadata(index), rawData(index))
    }

    @OverflowWrapping
    public override func getInt64(index: Int64): ?Int64 {
        return Int64.fromBinary(metadata(index), rawData(index))
    }

    public override func getUInt64(index: Int64): ?UInt64 {
        return UInt64.fromBinary(metadata(index), rawData(index))
    }


    public override func getFloat16(index: Int64): ?Float16 {
        return Float16.fromBinary(metadata(index), rawData(index))
    }

    public override func getFloat32(index: Int64): ?Float32 {
        return Float32.fromBinary(metadata(index), rawData(index))
    }

    public override func getFloat64(index: Int64): ?Float64 {
        return Float64.fromBinary(metadata(index), rawData(index))
    }

    public override func getBigInt(index: Int64): ?BigInt {
        return BigInt.fromBinary(metadata(index), rawData(index))
    }

    public override func getDecimal(index: Int64): ?Decimal {
        return Decimal.fromBinary(metadata(index), rawData(index))
    }

    public override func getDateTime(index: Int64): ?DateTime {
        return DateTime.fromBinary(metadata(index), rawData(index))
    }

    public override func getInputStream(index: Int64): ?InputStream {
        match (rawData(index)) {
            case None => return None
            case Some(v) => 
                let data = Array<Byte>(v.size, repeat: 0)
                v.copyTo(data)
                return ByteBuffer(data)
        }
    }

    @OverflowWrapping
    public override func getString(index: Int64): ?String {
        return String.fromBinary(metadata(index), rawData(index))
    }

    public override func getArray(index: Int64): ?Array<Byte> {
        match (rawData(index)) {
            case None => return None
            case Some(v) => 
                let columnType = metadata(index).columnType
                match (columnType) {
                    case String | VarString | Json | Enum | Set | TinyBlob | Blob | MediumBlob | LongBlob | Bit => 
                        let data = Array<Byte>(v.size, repeat: 0)
                        v.copyTo(data)
                        return data
                    case _ => 
                        throw UnsupportedException("Unsupported database type ${columnType} convert to Array")
                }
        }
    }

    public override func metadata(index: Int64): ColumnDefinition {
        return columns[index - 1]
    }

    private func rawData(index: Int64): ?Array<Byte> {
        return this.rows[currentRow].row[index - 1]
    }

}
