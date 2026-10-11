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
import std.convert.*
import std.math.numeric.*
import mariadb.protocol.*


protected class TextResultSet <: ResultSet {

    private let columns: Array<ColumnDefinition>

    private let rows: Array<TextResult>

    private var currentRow: Int64

    protected TextResultSet(columns: Array<ColumnDefinition>, rows: Array<TextResult>) {
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
        match (getString(index)) {
            case None => None
            case Some(v) => 
                if (v == "1") {
                    return true
                } else if(v == "0") {
                    return false
                }else {
                    throw ValueConvertException("Parse to Bool failed: column name is '${metadata(index).name}', raw value is ${v}")
                }
        }
    }

    public override func getInt8(index: Int64): ?Int8 {
        match (getString(index)) {
            case None => None
            case Some(v) => 
                try {
                    return Int8.parse(v)
                } catch (e: IllegalArgumentException) {
                    throw ValueConvertException("Parse to Int8 failed: column name is '${metadata(index).name}', raw value is ${v}")
                }
        }
    }

    public override func getUInt8(index: Int64): ?UInt8 {
        match (getString(index)) {
            case None => None
            case Some(v) => 
                try {
                    return UInt8.parse(v)
                } catch (e: IllegalArgumentException) {
                    throw ValueConvertException("Parse to UInt8 failed: column name is '${metadata(index).name}', raw value is ${v}")
                }
        }
    }

    public override func getInt16(index: Int64): ?Int16 {
        match (getString(index)) {
            case None => None
            case Some(v) => 
                try {
                    return Int16.parse(v)
                } catch (e: IllegalArgumentException) {
                    throw ValueConvertException("Parse to Int16 failed: column name is '${metadata(index).name}', raw value is ${v}")
                }
        }
    }

    public override func getUInt16(index: Int64): ?UInt16 {
        match (getString(index)) {
            case None => None
            case Some(v) => 
                try {
                    return UInt16.parse(v)
                } catch (e: IllegalArgumentException) {
                    throw ValueConvertException("Parse to UInt16 failed: column name is '${metadata(index).name}', raw value is ${v}")
                }
        }
    }

    public override func getInt32(index: Int64): ?Int32 {
        match (getString(index)) {
            case None => None
            case Some(v) =>
                try {
                    return Int32.parse(v)
                } catch (e: IllegalArgumentException) {
                    throw ValueConvertException("Parse to Int32 failed: column name is '${metadata(index).name}', raw value is ${v}")
                }
        }
    }

    public override func getUInt32(index: Int64): ?UInt32 {
        match (getString(index)) {
            case None => None
            case Some(v) => 
                try {
                    return UInt32.parse(v)
                } catch (e: IllegalArgumentException) {
                    throw ValueConvertException("Parse to UInt32 failed: column name is '${metadata(index).name}', raw value is ${v}")
                }
        }
    }

    public override func getInt64(index: Int64): ?Int64 {
        match (getString(index)) {
            case None => None
            case Some(v) => 
                try {
                    return Int64.parse(v)
                } catch (e: IllegalArgumentException) {
                    throw ValueConvertException("Parse to Int64 failed: column name is '${metadata(index).name}', raw value is ${v}")
                }
        }
    }

    public override func getUInt64(index: Int64): ?UInt64 {
        match (getString(index)) {
            case None => None
            case Some(v) => 
                try {
                    return UInt64.parse(v)
                } catch (e: IllegalArgumentException) {
                    throw ValueConvertException("Parse to UInt64 failed: column name is '${metadata(index).name}', raw value is ${v}")
                }
        }
    }

    public override func getFloat16(index: Int64): ?Float16 {
        match (getString(index)) {
            case None => None
            case Some(v) => 
                try {
                    return Float16.parse(v)
                } catch (e: IllegalArgumentException) {
                    throw ValueConvertException("Parse to Float16 failed: column name is '${metadata(index).name}', raw value is ${v}")
                }
        }
    }

    public override func getFloat32(index: Int64): ?Float32 {
        match (getString(index)) {
            case None => None
            case Some(v) => 
                try {
                    return Float32.parse(v)
                } catch (e: IllegalArgumentException) {
                    throw ValueConvertException("Parse to Float32 failed: column name is '${metadata(index).name}', raw value is ${v}")
                }
        }
    }

    public override func getFloat64(index: Int64): ?Float64 {
        match (getString(index)) {
            case None => None
            case Some(v) => 
                try {
                    return Float64.parse(v)
                } catch (e: IllegalArgumentException) {
                    throw ValueConvertException("Parse to Float64 failed: column name is '${metadata(index).name}', raw value is ${v}")
                }
        }
    }

    public override func getBigInt(index: Int64): ?BigInt {
        match (getString(index)) {
            case None => None
            case Some(v) => 
                try {
                    return BigInt.parse(v)
                } catch (e: IllegalArgumentException) {
                    throw ValueConvertException("Parse to BigInt failed: column name is '${metadata(index).name}', raw value is ${v}")
                }
        }
    }

    public override func getDecimal(index: Int64): ?Decimal {
        match (getString(index)) {
            case None => None
            case Some(v) =>         
                try {
                    return Decimal.parse(v)
                } catch (e: IllegalArgumentException) {
                    throw ValueConvertException("Parse to Float64 failed: column name is '${metadata(index).name}', raw value is ${v}")
                }
        }
    }

    public override func getDateTime(index: Int64): ?DateTime {
        match (getString(index)) {
            case None => None
            case Some(v) => 
                try {
                    match (v.size) {
                        case 8 => DateTime.parse(DB_TIME_PREFIX + v, DB_DATE_TIME_FORMAT)
                        case 10 => DateTime.parse(v + DB_DATE_SUFFIX, DB_DATE_TIME_FORMAT)
                        case _ => DateTime.parse(v, DB_DATE_TIME_FORMAT)
                    }
                } catch (e: TimeParseException) {
                    throw ValueConvertException("Parse to DateTime failed: column name is '${metadata(index).name}', raw value is ${v}")
                }
        }
    }

    public override func getInputStream(index: Int64): ?InputStream {
        match (getArray(index)) {
            case None => None
            case Some(v) => 
                let data = Array<Byte>(v.size, repeat: 0)
                v.copyTo(data)
                return ByteBuffer(data)
        }
    }

    public override func getString(index: Int64): ?String {
        match (rawData(index)) {
            case None => None
            case Some(v) => String.fromUtf8(v)
        }
    }

    public override func getArray(index: Int64): ?Array<Byte> {
        match (rawData(index)) {
            case None => None
            case Some(v) => 
                let data = Array<Byte>(v.size, repeat: 0)
                v.copyTo(data)
                return data
        }
    }

    public override func metadata(index: Int64): ColumnDefinition {
        return columns[index - 1]
    }

    private func rawData(index: Int64): ?Array<Byte> {
        return this.rows[currentRow].row[index - 1]
    }

}
