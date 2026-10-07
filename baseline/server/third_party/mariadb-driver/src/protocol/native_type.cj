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
import std.math.numeric.*

protected interface NativeType {

    func writeValue(buffer: ByteBuffer): Unit

    func writeType(buffer: ByteBuffer): Unit

}

extend Bool <: NativeType {

    public func writeValue(buffer: ByteBuffer): Unit {
        if(this) {
            [1] |> buffer.write
        } else {
            [0] |> buffer.write
        }
    }

    public func writeType(buffer: ByteBuffer): Unit {
       [ColumnType.Tiny.value(), 0x00] |> buffer.write
    }

}

extend Int8 <: NativeType {

    public func writeValue(buffer: ByteBuffer): Unit {
        this.toLittleEndian() |> buffer.write
    }

    public func writeType(buffer: ByteBuffer): Unit {
       [ColumnType.Tiny.value(), 0x00] |> buffer.write
    }

}

extend UInt8 <: NativeType {

    public func writeValue(buffer: ByteBuffer): Unit {
        this.toLittleEndian() |> buffer.write
    }

    public func writeType(buffer: ByteBuffer): Unit {
        [ColumnType.Tiny.value(), 0x80] |> buffer.write
    }

}

extend Int16 <: NativeType {

    public func writeValue(buffer: ByteBuffer): Unit {
        this.toLittleEndian() |> buffer.write
    }

    public func writeType(buffer: ByteBuffer): Unit {
        [ColumnType.Short.value(), 0x00] |> buffer.write
    }

}

extend UInt16 <: NativeType {

    public func writeValue(buffer: ByteBuffer): Unit {
        this.toLittleEndian() |> buffer.write
    }

    public func writeType(buffer: ByteBuffer): Unit {
        [ColumnType.Short.value(), 0x80] |> buffer.write
    }

}

extend Int32 <: NativeType {

    public func writeValue(buffer: ByteBuffer): Unit {
        this.toLittleEndian() |> buffer.write
    }

    public func writeType(buffer: ByteBuffer): Unit {
        [ColumnType.Long.value(), 0x00] |> buffer.write
    }

}

extend UInt32 <: NativeType {

    public func writeValue(buffer: ByteBuffer): Unit {
        this.toLittleEndian() |> buffer.write
    }

    public func writeType(buffer: ByteBuffer): Unit {
        [ColumnType.Long.value(), 0x80] |> buffer.write
    }

}

extend Int64 <: NativeType {

    public func writeValue(buffer: ByteBuffer): Unit {
        this.toLittleEndian() |> buffer.write
    }

    public func writeType(buffer: ByteBuffer): Unit {
        [ColumnType.LongLong.value(), 0x00] |> buffer.write
    }

}

extend UInt64 <: NativeType {


    public func writeValue(buffer: ByteBuffer): Unit {
        this.toLittleEndian() |> buffer.write
    }

    public func writeType(buffer: ByteBuffer): Unit {
        [ColumnType.LongLong.value(), 0x80] |> buffer.write
    }

}

extend Float16 <: NativeType {

    public func writeValue(buffer: ByteBuffer): Unit {
        this.toLittleEndian() |> buffer.write
    }

    public func writeType(buffer: ByteBuffer): Unit {
        [ColumnType.Float.value(), 0x00] |> buffer.write
    }

}

extend Float32 <: NativeType {

    public func writeValue(buffer: ByteBuffer): Unit {
        this.toLittleEndian() |> buffer.write
    }

    public func writeType(buffer: ByteBuffer): Unit {
        [ColumnType.Float.value(), 0x00] |> buffer.write
    }

}

extend Float64 <: NativeType {

    public func writeValue(buffer: ByteBuffer): Unit {
        this.toLittleEndian() |> buffer.write
    }

    public func writeType(buffer: ByteBuffer): Unit {
        [ColumnType.Double.value(), 0x00] |> buffer.write
    }

}

extend Rune <: NativeType {

    public func writeValue(buffer: ByteBuffer): Unit {
        this.toString() |> buffer.writeLengthEncoded
    }

    public func writeType(buffer: ByteBuffer): Unit {
        [ColumnType.VarString.value(), 0x00] |> buffer.write
    }

}

extend Array<Byte> <: NativeType {

    public func writeValue(buffer: ByteBuffer): Unit {
        return this |> buffer.writeLengthEncoded
    }

    public func writeType(buffer: ByteBuffer): Unit {
        [ColumnType.LongBlob.value(), 0x00] |> buffer.write
    }

}

extend String <: NativeType {

    public func writeValue(buffer: ByteBuffer): Unit {
        this |> buffer.writeLengthEncoded
    }

    public func writeType(buffer: ByteBuffer): Unit {
        [ColumnType.VarString.value(), 0x00] |> buffer.write
    }

}

extend DateTime <: NativeType {

    public func writeValue(buffer: ByteBuffer): Unit {
        7 |> buffer.write
        UInt16(year).toLittleEndian() |> buffer.write
        UInt8(month.toInteger()) |> buffer.write
        UInt8(dayOfMonth) |> buffer.write
        UInt8(hour) |> buffer.write
        UInt8(minute) |> buffer.write
        UInt8(second) |> buffer.write
    }

    public func writeType(buffer: ByteBuffer): Unit {
        [ColumnType.Timestamp.value(), 0x00] |>  buffer.write
    }

}

extend BigInt <: NativeType {

    public func writeValue(buffer: ByteBuffer): Unit {
        this.toString() |> buffer.writeLengthEncoded
    }

    public func writeType(buffer: ByteBuffer): Unit {
        [ColumnType.VarString.value(), 0x00] |>  buffer.write
    }

}

extend Decimal <: NativeType {

    public func writeValue(buffer: ByteBuffer): Unit {
        this.toString() |> buffer.writeLengthEncoded
    }

    public func writeType(buffer: ByteBuffer): Unit {
        [ColumnType.VarString.value(), 0x00] |>  buffer.write
    }

}