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

import std.binary.*

protected interface LittleEndian<T> {

    func toLittleEndian(): Array<Byte>

    static func fromLittleEndian(buffer: Array<Byte>): T

}

extend Int8 <: LittleEndian<Int8> {

    public func toLittleEndian(): Array<Byte> {
        let buffer = Array<Byte>(1, repeat: 0)
        this.writeLittleEndian(buffer)
        return buffer
    }

    public static func fromLittleEndian(buffer: Array<Byte>): Int8 {
        if(buffer.size != 1) {
            throw IllegalArgumentException("Buffer size must equals 1")
        }
        return Int8.readLittleEndian(buffer)
    }
}

extend Int16 <: LittleEndian<Int16> {

    public func toLittleEndian(): Array<Byte> {
        let buffer = Array<Byte>(2, repeat: 0)
        this.writeLittleEndian(buffer)
        return buffer
    }

    public static func fromLittleEndian(buffer: Array<Byte>): Int16 {
        if(buffer.size < 1 || buffer.size > 2) {
            throw IllegalArgumentException("Buffer size must between 1 and 2")
        }
        if(buffer.size < 2) {
            let temp = Array<Byte>(2, repeat: 0)
            buffer.copyTo(temp, 0, 0, buffer.size)
            return Int16.readLittleEndian(temp)
        } else {
            return Int16.readLittleEndian(buffer)
        }
    }
}

extend Int32 <: LittleEndian<Int32> {

    public func toLittleEndian(): Array<Byte> {
        let buffer = Array<Byte>(4, repeat: 0)
        this.writeLittleEndian(buffer)
        return buffer
    }

    public static func fromLittleEndian(buffer: Array<Byte>): Int32 {
        if(buffer.size < 1 || buffer.size > 4) {
            throw IllegalArgumentException("Buffer size must between 1 and 4")
        }
        if(buffer.size < 4) {
            let temp = Array<Byte>(4, repeat: 0)
            buffer.copyTo(temp, 0, 0, buffer.size)
            return Int32.readLittleEndian(temp)
        } else {
            return Int32.readLittleEndian(buffer)
        }
    }
}

extend Int64 <: LittleEndian<Int64> {

    public func toLittleEndian(): Array<Byte> {
        let buffer = Array<Byte>(8, repeat: 0)
        this.writeLittleEndian(buffer)
        return buffer
    }

    public static func fromLittleEndian(buffer: Array<Byte>): Int64 {
        if(buffer.size < 1 || buffer.size > 8) {
            throw IllegalArgumentException("Buffer size must between 1 and 8")
        }
        if(buffer.size < 8) {
            let temp = Array<Byte>(8, repeat: 0)
            buffer.copyTo(temp, 0, 0, buffer.size)
            return Int64.readLittleEndian(temp)
        } else {
            return Int64.readLittleEndian(buffer)
        }
    }

}

extend UInt8 <: LittleEndian<UInt8> {

    public func toLittleEndian(): Array<Byte> {
        return [this]
    }

    public static func fromLittleEndian(buffer: Array<Byte>): UInt8 {
        if (buffer.size != 1) {
            throw IllegalArgumentException("buffer size must equals 1 ")
        }
        return buffer[0]
    }
}

extend UInt16 <: LittleEndian<UInt16> {

    public func toLittleEndian(): Array<Byte> {
        let buffer = Array<Byte>(2, repeat: 0)
        this.writeLittleEndian(buffer)
        return buffer
    }

    public static func fromLittleEndian(buffer: Array<Byte>): UInt16 {
        if(buffer.size < 1 || buffer.size > 2) {
            throw IllegalArgumentException("Buffer size must between 1 and 2")
        }
        if(buffer.size < 2) {
            let temp = Array<Byte>(2, repeat: 0)
            buffer.copyTo(temp, 0, 0, buffer.size)
            return UInt16.readLittleEndian(temp)
        } else {
            return UInt16.readLittleEndian(buffer)
        }
    }
}

extend UInt32 <: LittleEndian<UInt32> {

    public func toLittleEndian(): Array<Byte> {
        let buffer = Array<Byte>(4, repeat: 0)
        this.writeLittleEndian(buffer)
        return buffer
    }

    public static func fromLittleEndian(buffer: Array<Byte>): UInt32 {
        if(buffer.size < 1 || buffer.size > 4) {
            throw IllegalArgumentException("Buffer size must between 1 and 4")
        }
        if(buffer.size < 4) {
            let temp = Array<Byte>(4, repeat: 0)
            buffer.copyTo(temp, 0, 0, buffer.size)
            return UInt32.readLittleEndian(temp)
        } else {
            return UInt32.readLittleEndian(buffer)
        }
    }
}

extend UInt64 <: LittleEndian<UInt64> {

    public func toLittleEndian(): Array<Byte> {
        let buffer = Array<Byte>(8, repeat: 0)
        this.writeLittleEndian(buffer)
        return buffer
    }

    public static func fromLittleEndian(buffer: Array<Byte>): UInt64 {
        if(buffer.size < 1 || buffer.size > 8) {
            throw IllegalArgumentException("Buffer size must between 1 and 8")
        }
        if(buffer.size < 8) {
            let temp = Array<Byte>(8, repeat: 0)
            buffer.copyTo(temp, 0, 0, buffer.size)
            return UInt64.readLittleEndian(temp)
        } else {
            return UInt64.readLittleEndian(buffer)
        }
    }
}

extend Float16 <: LittleEndian<Float16> {
    
    public func toLittleEndian(): Array<Byte> {
        let buffer = Array<Byte>(2, repeat: 0)
        this.writeLittleEndian(buffer)
        return buffer
    }

    public static func fromLittleEndian(buffer: Array<Byte>): Float16 {
        return readLittleEndian(buffer)
    }
}

extend Float32 <: LittleEndian<Float32> {
    
    public func toLittleEndian(): Array<Byte> {
        let buffer = Array<Byte>(4, repeat: 0)
        this.writeLittleEndian(buffer)
        return buffer
    }

    public static func fromLittleEndian(buffer: Array<Byte>): Float32 {
        return readLittleEndian(buffer)
    }
}

extend Float64 <: LittleEndian<Float64> {
    
    public func toLittleEndian(): Array<Byte> {
        let buffer = Array<Byte>(8, repeat: 0)
        this.writeLittleEndian(buffer)
        return buffer
    }

    public static func fromLittleEndian(buffer: Array<Byte>): Float64 {
        return readLittleEndian(buffer)
    }
}