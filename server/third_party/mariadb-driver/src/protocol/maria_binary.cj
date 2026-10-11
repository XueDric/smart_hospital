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
protected package mariadb.protocol

import std.io.*
import std.time.*
import std.convert.*
import std.math.numeric.*

protected interface MariaBinary<T> {

    static func fromBinary(definition: ColumnDefinition, data: ?Array<Byte>): ?T

}


extend Bool <: MariaBinary<Bool> {

    public static func fromBinary(definition: ColumnDefinition, data: ?Array<Byte>): ?Bool {
        let value = UInt8.fromBinary(definition, data)
        match (value) {
            case None => None
            case Some(0) => false
            case Some(1) => true
            case Some(v) => throw IllegalArgumentException("Value ${v} cannot be converted to Cangjie Bool types")
        }
    }

}

extend Int8 <: MariaBinary<Int8> {

    public static func fromBinary(definition: ColumnDefinition, data: ?Array<Byte>): ?Int8 {
        match (data) {
            case None => return None
            case Some(v) => 
                let columnType = definition.columnType
                match (definition.columnType) {
                    case Tiny => 
                        return Int8.fromLittleEndian(v)
                    case Short | Year => 
                        return Int8(Int16.fromLittleEndian(v))
                    case Long | Int24 => 
                        return Int8(Int32.fromLittleEndian(v))
                    case LongLong => 
                        return Int8(Int64.fromLittleEndian(v))
                    case Float => 
                        return Int8(Float32.fromLittleEndian(v))
                    case Double => 
                        return Int8(Float64.fromLittleEndian(v))
                    case String | VarString | NewDecimal =>
                        var str = String.fromUtf8(v)
                        return Int8.parse(str)
                    case _ => 
                        throw IllegalArgumentException("${columnType} types cannot be converted to Cangjie Int8 types")
                }
        }
    }

}

extend UInt8 <: MariaBinary<UInt8> {

    public static func fromBinary(definition: ColumnDefinition, data: ?Array<Byte>): ?UInt8 {
        match (data) {
            case None => return None
            case Some(v) => 
                let columnType = definition.columnType
                match (columnType) {
                    case Tiny => 
                        return UInt8.fromLittleEndian(v)
                    case Short | Year => 
                        return UInt8(UInt16.fromLittleEndian(v))
                    case Long | Int24 => 
                        return UInt8(UInt32.fromLittleEndian(v))
                    case LongLong => 
                        return UInt8(UInt64.fromLittleEndian(v))
                    case Float => 
                        return UInt8(Float32.fromLittleEndian(v))
                    case Double => 
                        return UInt8(Float64.fromLittleEndian(v))
                    case String | VarString | NewDecimal =>
                        var str = String.fromUtf8(v)
                        return UInt8.parse(str)
                    case _ => 
                        throw IllegalArgumentException("${columnType} types cannot be converted to Cangjie UInt8 types")
                }
        }
    }

}

extend Int16 <: MariaBinary<Int16> {

    public static func fromBinary(definition: ColumnDefinition, data: ?Array<Byte>): ?Int16 {
        match (data) {
            case None => return None
            case Some(v) => 
                let columnType = definition.columnType
                match (columnType) {
                    case Tiny => 
                        return Int16(Int8.fromLittleEndian(v))
                    case Short | Year => 
                        return Int16.fromLittleEndian(v)
                    case Long | Int24 => 
                        return Int16(Int32.fromLittleEndian(v))
                    case LongLong => 
                        return Int16(Int64.fromLittleEndian(v))
                    case Float => 
                        return Int16(Float32.fromLittleEndian(v))
                    case Double => 
                        return Int16(Float64.fromLittleEndian(v))
                    case String | VarString | NewDecimal =>
                        var str = String.fromUtf8(v)
                        return Int16.parse(str)
                    case _ => 
                        throw IllegalArgumentException("${columnType} types cannot be converted to Cangjie Int16 types")
                }
        }
    }

}

extend UInt16 <: MariaBinary<UInt16> {

    public static func fromBinary(definition: ColumnDefinition, data: ?Array<Byte>):? UInt16 {
        match (data) {
            case None => return None
            case Some(v) => 
                let columnType = definition.columnType
                match (columnType) {
                    case Tiny => 
                        return UInt16(UInt8.fromLittleEndian(v))
                    case Short | Year => 
                        return UInt16.fromLittleEndian(v)
                    case Long | Int24 => 
                        return UInt16(UInt32.fromLittleEndian(v))
                    case LongLong => 
                        return UInt16(UInt64.fromLittleEndian(v))
                    case Float => 
                        return UInt16(Float32.fromLittleEndian(v))
                    case Double => 
                        return UInt16(Float64.fromLittleEndian(v))
                    case String | VarString | NewDecimal =>
                        var str = String.fromUtf8(v)
                        return UInt16.parse(str)
                    case _ => 
                        throw IllegalArgumentException("${columnType} types cannot be converted to Cangjie UInt16 types")
                }
        }
    }

}

extend Int32 <: MariaBinary<Int32> {

    public static func fromBinary(definition: ColumnDefinition, data: ?Array<Byte>): ?Int32 {
        match (data) {
            case None => return None
            case Some(v) => 
                let columnType = definition.columnType
                match (columnType) {
                    case Tiny => 
                        return Int32(Int8.fromLittleEndian(v))
                    case Short | Year => 
                        return Int32(Int16.fromLittleEndian(v))
                    case Long | Int24 => 
                        return Int32.fromLittleEndian(v)
                    case LongLong => 
                        return Int32(Int64.fromLittleEndian(v))
                    case Float => 
                        return Int32(Float32.fromLittleEndian(v))
                    case Double => 
                        return Int32(Float64.fromLittleEndian(v))
                    case String | VarString | NewDecimal =>
                        var str = String.fromUtf8(v)
                        return Int32.parse(str)
                    case _ => 
                        throw IllegalArgumentException("${columnType} types cannot be converted to Cangjie Int32 types")
                }
        }
    }
}

extend UInt32 <: MariaBinary<UInt32> {

    public static func fromBinary(definition: ColumnDefinition, data: ?Array<Byte>): ?UInt32 {
        match (data) {
            case None => return None
            case Some(v) => 
                let columnType = definition.columnType
                match (columnType) {
                    case Tiny => 
                        return UInt32(UInt8.fromLittleEndian(v))
                    case Short | Year => 
                        return UInt32(UInt16.fromLittleEndian(v))
                    case Long | Int24 => 
                        return UInt32.fromLittleEndian(v)
                    case LongLong => 
                        return UInt32(UInt64.fromLittleEndian(v))
                    case Float => 
                        return UInt32(Float32.fromLittleEndian(v))
                    case Double => 
                        return UInt32(Float64.fromLittleEndian(v))
                    case String | VarString | NewDecimal =>
                        var str = String.fromUtf8(v)
                        return UInt32.parse(str)
                    case _ => 
                        throw IllegalArgumentException("${columnType} types cannot be converted to Cangjie UInt32 types")
                }
        }
    }
}

extend Int64 <: MariaBinary<Int64> {

    public static func fromBinary(definition: ColumnDefinition, data: ?Array<Byte>): ?Int64 {
        match (data) {
            case None => return None
            case Some(v) => 
                let columnType = definition.columnType
                match (columnType) {
                    case Tiny => 
                        return Int64(Int8.fromLittleEndian(v))
                    case Short | Year => 
                        return Int64(Int16.fromLittleEndian(v))
                    case Long | Int24 => 
                        return Int64(Int32.fromLittleEndian(v))
                    case LongLong => 
                        return Int64.fromLittleEndian(v)
                    case Float => 
                        return Int64(Float32.fromLittleEndian(v))
                    case Double => 
                        return Int64(Float64.fromLittleEndian(v))
                    case String | VarString | NewDecimal =>
                        var str = String.fromUtf8(v)
                        return Int64.parse(str)
                    case _ => 
                        throw IllegalArgumentException("${columnType} types cannot be converted to Cangjie Int64 types")
                }
        }
    }

}

extend UInt64 <: MariaBinary<UInt64> {

    public static func fromBinary(definition: ColumnDefinition, data: ?Array<Byte>): ?UInt64 {
        match (data) {
            case None => return None
            case Some(v) => 
                let columnType = definition.columnType
                match (columnType) {
                    case Tiny => 
                        return UInt64(UInt8.fromLittleEndian(v))
                    case Short | Year => 
                        return UInt64(UInt16.fromLittleEndian(v))
                    case Long | Int24 => 
                        return UInt64(UInt32.fromLittleEndian(v))
                    case LongLong => 
                        return UInt64.fromLittleEndian(v)
                    case Float => 
                        return UInt64(Float32.fromLittleEndian(v))
                    case Double => 
                        return UInt64(Float64.fromLittleEndian(v))
                    case String | VarString | NewDecimal =>
                        var str = String.fromUtf8(v)
                        return UInt64.parse(str)
                    case _ => 
                        throw IllegalArgumentException("${columnType} types cannot be converted to Cangjie UInt64 types")
                }
        }
    }

}

extend Float16 <: MariaBinary<Float16> {

    public static func fromBinary(definition: ColumnDefinition, data: ?Array<Byte>): ?Float16 {
        match (data) {
            case None => return None
            case Some(v) => 
                let columnType = definition.columnType
                match (columnType) {
                    case Float => 
                        return Float16(Float32.fromLittleEndian(v))
                    case Double => 
                        return Float16(Float64.fromLittleEndian(v))
                    case String | VarString => 
                        return Float16.parse(String.fromUtf8(v))
                    case _ => 
                        throw IllegalArgumentException("${columnType} types cannot be converted to Cangjie Float16 types")
                }   
        }
    }

}

extend Float32 <: MariaBinary<Float32> {

    public static func fromBinary(definition: ColumnDefinition, data: ?Array<Byte>): ?Float32 {
        match(data) {
            case None => return None
            case Some(v) => 
                let columnType = definition.columnType
                match (columnType) {
                    case Float => 
                        return Float32.fromLittleEndian(v)
                    case Double => 
                        return Float32(Float64.fromLittleEndian(v))
                    case String | VarString | NewDecimal => 
                        return Float32.parse(String.fromUtf8(v))
                    case _ => 
                        throw IllegalArgumentException("${columnType} types cannot be converted to Cangjie Float32 types")
                }
        }
    }

}

extend Float64 <: MariaBinary<Float64> {

    public static func fromBinary(definition: ColumnDefinition, data: ?Array<Byte>): ?Float64 {
        match(data) {
            case None => return None
            case Some(v) => 
                let columnType = definition.columnType
                match (columnType) {
                    case Float => 
                        return Float64(Float32.fromLittleEndian(v))
                    case Double => 
                        return Float64.fromLittleEndian(v)
                    case String | VarString | NewDecimal => 
                        return Float64.parse(String.fromUtf8(v))
                    case _ => 
                        throw IllegalArgumentException("${columnType} types cannot be converted to Cangjie Float64 types")
                }
        }
    }

}

extend String <: MariaBinary<String> {

    public static func fromBinary(definition: ColumnDefinition, data: ?Array<Byte>): ?String {
        match (data) {
            case None => return None
            case Some(v) => 
                let columnType = definition.columnType
                let unsigned = definition.hasFlag(Unsigned)
                match (columnType) {
                    case Tiny =>
                        if (!unsigned) {
                            return Int8.fromLittleEndian(v).toString()
                        } else {
                            return UInt8.fromLittleEndian(v).toString()
                        }
                    case Short | Year =>
                        if (!unsigned) {
                            return Int16.fromLittleEndian(v).toString()
                        } else {
                            return UInt16.fromLittleEndian(v).toString()
                        }
                    case Long | Int24 =>
                        if (!unsigned) {
                            return Int32.fromLittleEndian(v).toString()
                        } else {
                            return UInt32.fromLittleEndian(v).toString()
                        }
                    case LongLong =>
                        if (!unsigned) {
                            return Int64.fromLittleEndian(v).toString()
                        } else {
                            return UInt64.fromLittleEndian(v).toString()
                        }
                    case Float => 
                        return Float32.fromLittleEndian(v).toString()
                    case Double => 
                        return Float64.fromLittleEndian(v).toString()
                    case VarString | String | Json | Enum | Set | TinyBlob | MediumBlob | LongBlob | Blob | NewDecimal =>
                        return String.fromUtf8(v)
                        // match (charset) {
                        //     case Binary => 
                        //         throw Exception("Unsupported Charset: Binary")
                        //     case Utf8mb3GeneralCi => 
                        //         return String.fromUtf8(data)
                        //     case Latin1SwedishCi => 
                        //         throw Exception("Unsupported Charset: Latin1SwedishCi")
                        // }
                    case Date => 
                        return DateTime.fromBinaryDateTime(v).toString()
                    case DateTime | Timestamp => 
                        return DateTime.fromBinaryDateTime(v).toString()
                    case Time => 
                        return DateTime.fromBinaryTime(v).toString()
                    case _ => 
                        throw IllegalArgumentException("${columnType} types cannot be converted to Cangjie String types")
                    }
        }
    }

}

extend BigInt <: MariaBinary<BigInt> {

    public static func fromBinary(definition: ColumnDefinition, data: ?Array<Byte>): ?BigInt {
        match (data) {
            case None => return None
            case Some(v) => 
                let columnType = definition.columnType
                match (columnType) {
                    case Tiny => 
                        return BigInt(Int8.fromLittleEndian(v))
                    case Short | Year => 
                        return BigInt(Int16.fromLittleEndian(v))
                    case Int24 | Long => 
                        return BigInt(Int32.fromLittleEndian(v))
                    case LongLong => 
                        return BigInt(Int64.fromLittleEndian(v))
                case String | VarString | Enum | Set | TinyBlob | MediumBlob | LongBlob | Blob | NewDecimal => 
                    return BigInt.parse(String.fromUtf8(v))
                case _ => 
                    throw IllegalArgumentException("${columnType} types cannot be converted to Cangjie BigInt types")
                }
        }
    }

}

extend Decimal <: MariaBinary<Decimal> {

    public static func fromBinary(definition: ColumnDefinition, data: ?Array<Byte>): ?Decimal {
        match (data) {
            case None => return None
            case Some(v) => 
                let columnType = definition.columnType
                match (columnType) {
                    case Float => 
                        return Decimal(Float32.fromLittleEndian(v))
                    case Double => 
                        return Decimal(Float64.fromLittleEndian(v))
                    case String | VarString | NewDecimal | TinyBlob | MediumBlob | LongBlob | Blob => 
                        Decimal.parse(String.fromUtf8(v))
                    case _ => 
                        throw IllegalArgumentException("${columnType} types cannot be converted to Cangjie Decimal types")
                }
        }
    }

}


extend DateTime <: MariaBinary<DateTime> {

    public static func fromBinary(definition: ColumnDefinition, data: ?Array<Byte>): ?DateTime {
        match(data) {
            case None => return None
            case Some(v) => 
                let columnType = definition.columnType
                match (columnType) {
                    case Date => 
                        return DateTime.fromBinaryDateTime(v)
                    case DateTime | Timestamp => 
                        return DateTime.fromBinaryDateTime(v)
                    case Time => 
                        return DateTime.fromBinaryTime(v)
                    case _ => 
                        throw IllegalArgumentException("${columnType} types cannot be converted to Cangjie DateTime types")
                }
        }
    }

}

extend DateTime {
    
    protected static func fromBinaryDateTime(data: Array<Byte>): DateTime {
        let buffer = ByteBuffer(data)
        match (data.size) {
            case 0 => throw IllegalFormatException()
            case 4 =>
                let year = buffer.readInt2()
                let month = buffer.readInt1()
                let day = buffer.readInt1()
                return DateTime.of(year: Int64(year), month: Int64(month), dayOfMonth: Int64(day), timeZone: TimeZone.Local)
            case 7 =>
                let year = buffer.readInt2()
                let month = buffer.readInt1()
                let day = buffer.readInt1()
                let hour = buffer.readInt1()
                let minute = buffer.readInt1()
                let second = buffer.readInt1()
                return DateTime.of(year: Int64(year), month: Int64(month), dayOfMonth: Int64(day), hour: Int64(hour), minute: Int64(minute), second: Int64(second), timeZone: TimeZone.Local)
            case 11 =>
                let year = buffer.readInt2()
                let month = buffer.readInt1()
                let day = buffer.readInt1()
                let hour = buffer.readInt1()
                let minute = buffer.readInt1()
                let second = buffer.readInt1()
                let micorSecond = buffer.readInt4()
                return DateTime.of(year: Int64(year),month: Int64(month),dayOfMonth: Int64(day),hour: Int64(hour), minute: Int64(minute),second: Int64(second),nanosecond: Int64(micorSecond),timeZone: TimeZone.Local)
            case _ => throw InvalidPacketException("")
        }
    }

    protected static func fromBinaryTime(data: Array<Byte>): DateTime {
        let buffer = ByteBuffer(data)
        match (data.size) {
            case 0 => throw IllegalFormatException()
            case 8 =>
                let _ = buffer.readInt1() //negative
                let _ = buffer.readInt4() //day
                let hour = buffer.readInt1()
                let minute = buffer.readInt1()
                let second = buffer.readInt1()
                return DateTime.of(year: 1970, month: 1, dayOfMonth: 1, hour: Int64(hour), minute: Int64(minute),second: Int64(second), timeZone: TimeZone.Local)
            case 12 =>
                let _ = buffer.readInt1() //negative
                let _ = buffer.readInt4() //day
                let hour = buffer.readInt1()
                let minute = buffer.readInt1()
                let second = buffer.readInt1()
                let micorSecond = buffer.readInt4()
                return DateTime.of(year: 1970, month: 1, dayOfMonth: 1, hour: Int64(hour), minute: Int64(minute),second: Int64(second), nanosecond: Int64(micorSecond), timeZone: TimeZone.Local)
            case _ => throw InvalidPacketException("")
        }
    }

}