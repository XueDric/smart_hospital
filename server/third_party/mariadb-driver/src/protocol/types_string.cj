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

extend ByteBuffer {

    public func readArray(length: Int64): Array<Byte> {
        if (length == 0) {
            return []
        }
        // Use slicing operations instead of copying
        let data = this.bytes().slice(0, length)
        this.seek(Current(length))
        return data
    }

    public func readString(size: Int64): String {
        return String.fromUtf8(readArray(size))
    }

    public func readNullTerminatedString(): String {
        return String.fromUtf8(readNullTerminatedStringRaw())
    }

    public func readNullTerminatedStringRaw(): Array<Byte> {
        let offset = this.bytes().indexOf(0) ?? throw InvalidPacketException("read a null terminated string failed")
        let data = readArray(offset)
        this.readByte()//skip \0
        return data
    }

    public func readLengthEncodedString(): ?String {
        match (readLengthEncodedStringRaw()) {
            case None => return None
            case Some(v) => return String.fromUtf8(v)
        }
    }

    public func readLengthEncodedStringRaw(): ?Array<Byte> {
        match (readLengthEncodedInteger()) {
            case None => return None
            case Some(length) => return readArray(Int64(length))
        }
    }

}

extend ByteBuffer {

    public func writeArray(value: Array<Byte>): Unit {
        write(value)
    }

    public func writeString(value: String): Unit {
        write(value.toArray())
    }

    public func writeNullTerminated(value: String): Unit {
        writeNullTerminated(value.toArray())
    }

    public func writeNullTerminated(value: Array<Byte>): Unit {
        write(value)
        write(0x00)
    }

    public func writeLengthEncoded(value: String): Unit {
        writeLengthEncoded(value.toArray())
    }

    public func writeLengthEncoded(value: Array<Byte>): Unit {
        let size = value.size
        if (size <= 0xFA) {
            write(UInt8(size))
            write(value)
        } else if (size <= (1 << 16)) {
            write(0xFC)
            write(UInt16(size).toLittleEndian())
            write(value)
        } else if (size <= (1 << 24)) {
            write(0xFD)
            write(UInt32(size).toLittleEndian().slice(0, 3))
            write(value)
        } else {
            write(0xFE)
            write(UInt64(size).toLittleEndian())
            write(value)
        }
    }

}

