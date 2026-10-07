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

protected abstract class Request {

    private static let SINGLE_PACKAGE_MAX: Int64 = (1 << 24) - 1

    protected let buffer: ByteBuffer = ByteBuffer()

    protected var number: UInt8

    protected init(number: UInt8) {
        this.number = number
    }
    
    protected open func pack(): Unit
    
    protected func writeTo(outputStream: OutputStream): Unit {
        pack()
        let bytes = buffer.bytes()
        var size = bytes.size
        var i = 0u8
        //对超过16mb的数据包进行分包处理
        while (size > SINGLE_PACKAGE_MAX) {
            outputStream.write(UInt32(SINGLE_PACKAGE_MAX).toLittleEndian().slice(0, 3))
            outputStream.write(number + i)
            outputStream.write(bytes.slice(SINGLE_PACKAGE_MAX * Int64(i), SINGLE_PACKAGE_MAX))
            size -= SINGLE_PACKAGE_MAX
            i++
        }
        outputStream.write(UInt32(size).toLittleEndian().slice(0,3))
        outputStream.write(number + i)
        outputStream.write(bytes.slice(SINGLE_PACKAGE_MAX * Int64(i), size))
    }

}