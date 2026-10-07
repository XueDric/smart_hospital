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
import stdx.encoding.hex.*

//mariadb datetime类型的默认格式
protected const DB_DATE_TIME_FORMAT: String = "yyyy-MM-dd HH:mm:ss"

// //mariadb date类型的默认格式
// protected const DB_DATE_FORMAT: String = "yyyy-MM-dd"

// //mariadb time类型的默认格式
// protected const DB_TIME_FORMAT: String = "HH:mm:ss"

//mariadb time类型转DateTime的前缀
protected const DB_TIME_PREFIX: String = "1970-01-01 "

protected const DB_DATE_SUFFIX: String = " 00:00:00"


protected func escapeString(value: String): String {
    let builder = StringBuilder()
    builder.append("'")
    for(i in value.toRuneArray()) {
        match (i) {
            case r'\n' => builder.append("\\n")
            case r'\r' => builder.append("\\r")
            case r'\\' => builder.append("\\\\")
            case r'\'' => builder.append("\'\'")
            case r'"' => builder.append("\"")
            case _ => builder.append(i)
            }
        }
        builder.append("'")
        return builder.toString()
}

protected func toHexStringWithPrefix(inputStream: InputStream): String {
    let buffer = Array<Byte>(8096, repeat: 0)
    var len = inputStream.read(buffer)
    if(len == 0) {
        return "''"
    }
    let builder = StringBuilder()
    builder.append("0x")
    do {
        builder.append(toHexString(buffer.slice(0, len)))
        len = inputStream.read(buffer)
    } while (len != 0)
    return builder.toString()
}

protected func toHexStringWithPrefix(array: Array<Byte>): String {
    if(array.size == 0) {
        return "''"
    }
    return "0x${toHexString(array)}"
}

protected func toArray(inputStream: InputStream): Array<Byte> {
    let buffer = Array<Byte>(1024, repeat: 0)
    let bytes = ByteBuffer()
    var len = inputStream.read(buffer)
    do {
        bytes.write(buffer.slice(0, len))
        len = inputStream.read(buffer)
    } while (len != 0)
    return readToEnd(bytes)
}

extend String {


    public func toNullTerminated(): Array<Byte> {
        return this.toArray().toNullTerminated()
    }
    
}

extend Array<Byte>  {

    public func toNullTerminated(): Array<Byte> {
        let buf = Array<Byte>(this.size + 1, repeat: 0)
        this.copyTo(buf, 0, 0, this.size)
        return buf
    }

}