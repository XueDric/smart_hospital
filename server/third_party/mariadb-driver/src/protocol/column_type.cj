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

protected enum ColumnType <: ToString {
    //| Decimal
    | Tiny
    | Short
    | Long
    | Float
    | Double
    | Null
    | Timestamp
    | LongLong
    | Int24
    | Date
    | Time
    | DateTime
    | Year
    //| NewDate
    //| Varchar
    | Bit
    //| Timestamp2
    //| DateTime2
    //| Time2
    //| TypedArray 
    //| Invalid
    //| _Bool
    | Json
    | NewDecimal
    | Enum
    | Set
    | TinyBlob
    | MediumBlob
    | LongBlob
    | Blob
    | VarString
    | String
    //| Geometry

    protected static func of(value: Byte): ColumnType {
        match (value) {
            //case 0x00 => Decimal
            case 0x01 => Tiny
            case 0x02 => Short
            case 0x03 => Long
            case 0x04 => Float
            case 0x05 => Double
            case 0x06 => Null
            case 0x07 => Timestamp
            case 0x08 => LongLong
            case 0x09 => Int24
            case 0x0A => Date
            case 0x0B => Time
            case 0x0C => DateTime
            case 0x0D => Year
            //case 0x0E => NewDate
            //case 0x0F => Varchar
            case 0x10 => Bit
            //case 0x11 => Timestamp2
            //case 0x12 => DateTime2
            //case 0x13 => Time2
            //case 0x14 => TypedArray
            //case 0xF3 => Invalid
            //case 0xF4 => _Bool
            case 0xF5 => Json
            case 0xF6 => NewDecimal
            case 0xF7 => Enum
            case 0xF8 => Set
            case 0xF9 => TinyBlob
            case 0xFA => MediumBlob
            case 0xFB => LongBlob
            case 0xFC => Blob
            case 0xFD => VarString
            case 0xFE => String
            //case 0xFF => Geometry
            case _ => throw Exception("Don't have this ColumnType by value ${value}")
        }
    }

    protected func value(): Byte {
        match (this) {
            //case Decimal => 0x00
            case Tiny => 0x01
            case Short => 0x02
            case Long => 0x03
            case Float => 0x04
            case Double => 0x05
            case Null => 0x06 
            case Timestamp => 0x07
            case LongLong => 0x08
            case Int24 => 0x09
            case Date => 0x0A
            case Time => 0x0B
            case DateTime => 0x0C
            case Year => 0x0D
            //case NewDate => 0x0E 
            //case Varchar => 0x0F
            case Bit => 0x10
            //case Timestamp2 => 0x11
            //case DateTime2 => 0x12
            //case Time2 => 0x13
            //case TypedArray => 0x14
            //case Invalid => 0xF3
            //case _Bool => 0xF4
            case Json => 0xF5
            case NewDecimal => 0xF6
            case Enum => 0xF7
            case Set => 0xF8
            case TinyBlob => 0xF9
            case MediumBlob => 0xFA
            case LongBlob => 0xFB
            case Blob => 0xFC
            case VarString => 0xFD
            case String => 0xFE
            //case Geometry => 0xFF
        }
    }
    
    public func cangjieType(unsigned: Bool) {
        match (this) {
            case Tiny =>
                if (unsigned) {
                    "UInt8"
                } else {
                    "Int8"
                }
            case Short =>
                if (unsigned) {
                    "UInt16"
                } else {
                    "Int16"
                }
            case Int24 =>
                if (unsigned) {
                    "UInt32"
                } else {
                    "Int32"
                }
            case Long =>
                if (unsigned) {
                    "UInt32"
                } else {
                    "Int32"
                }
            case LongLong =>
                if (unsigned) {
                    "UInt64"
                } else {
                    "Int64"
                }
            case Float => "Float32"
            case Double => "Float64"
            case Null => "Option<Any>"
            case Timestamp => "DateTime"
            case Date => "DateTime"
            case Time => "DateTime"
            case DateTime => "DateTime"
            case Year => "Int32"
            case Bit => "Array<Byte>"
            case Json => "String"
            case NewDecimal => "Decimal"
            case Enum => "String"
            case Set => "String"
            case TinyBlob => "Array<Byte>"
            case MediumBlob => "Array<Byte>"
            case LongBlob => "Array<Byte>"
            case Blob => "Array<Byte>"
            case VarString => "String"
            case String => "String"
        }
    }

    public func toString() {
        match (this) {
            //case Decimal => "Decimal"
            case Tiny => "Tiny"
            case Short => "Short"
            case Long => "Long"
            case Float => "Float"
            case Double => "Double"
            case Null => "Null"
            case Timestamp => "Timestamp"
            case LongLong => "Long"
            case Int24 => "Int24"
            case Date => "Date"
            case Time => "Time"
            case DateTime => "DateTime"
            case Year => "Year"
            //case NewDate => "NewDate"
            //case Varchar => "Varchar"
            case Bit => "Bit"
            //case Timestamp2 => "Timestamp2"
            //case DateTime2 => "DateTime2"
            //case Time2 => "Time2"
            //case TypedArray => "TypedArray"
            //case Invalid => "Invalid"
            //case Bool => "Bool"
            case Json => "Json"
            case NewDecimal => "NewDecimal"
            case Enum => "Enum"
            case Set => "Set"
            case TinyBlob => "TinyBlob"
            case MediumBlob => "MediumBlob"
            case LongBlob => "LongBlob"
            case Blob => "Blob"
            case VarString => "VarString"
            case String => "String"
            //case Geometry => "Geometry"
        }
    }

    protected operator func ==(right: ColumnType) {
        return this.value() == right.value()
    }


}
