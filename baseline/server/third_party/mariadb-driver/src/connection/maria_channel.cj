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
import std.net.*
import mariadb.protocol.*

/*
* mariadb channl reads complete mariadb packages from the socket
*/
protected class MariaChannel <: Resource {

    private static let MAX_PACKAEG_SIZE: Int64 = (1 << 24) - 1

    private let length: Array<Byte> = Array<Byte>(3, repeat: 0)

    private let number: Array<Byte> = Array<Byte>(1, repeat: 0)

    private let buffer: Array<Byte> = Array<Byte>(1024, repeat: 0)

    protected var socket: StreamingSocket

    protected init(socket: TcpSocket) {
        this.socket = socket
    }

    public override func close() {
        socket.close()
    }

    public override func isClosed(): Bool {
        return socket.isClosed()
    }

    protected func read(): (UInt64, UInt8, ByteBuffer) {
        var total = 0
        fillIn(length)
        fillIn(number)
        var len = UInt32.fromLittleEndian(length)
        var num = UInt8.fromLittleEndian(number)
        let bytes = ByteBuffer(Int64(len))
        //对超过16mb的数据包进行整合                     
        while (Int64(len) == MAX_PACKAEG_SIZE) {
            fillIn(MAX_PACKAEG_SIZE, bytes)
            total += Int64(len)
            fillIn(length)
            fillIn(number)
            len = UInt32.fromLittleEndian(length)
            num = UInt8.fromLittleEndian(number)
        }
        fillIn(Int64(len), bytes)
        total += Int64(len)
        return (UInt64(total), num, bytes)
    }

    private func fillIn(length: Int64, dest: ByteBuffer) {
        var readed = 0
        while(readed < length) {
            let remaining = length - readed
            if(remaining >= Int64(buffer.size)) {
                let len = socket.read(buffer)
                dest.write(buffer.slice(0, len))
                readed += Int64(len)
            }else {
                let temp = Array<Byte>(Int64(remaining), repeat: 0)
                let len = socket.read(temp)
                dest.write(temp.slice(0, len))
                readed += Int64(len)
            }
        }
    }

    private func fillIn(b: Array<Byte>) {
        var readed = 0i64
        while(readed < b.size) {
            let remaining = b.size - readed
            if(remaining >= buffer.size) {
                let len = socket.read(buffer)
                buffer.copyTo(b, 0, readed, len)
                readed += len 
            } else {
                let temp = Array<Byte>(remaining, repeat: 0)
                let len = socket.read(temp)
                temp.copyTo(b, 0, readed, len)
                readed += len
            }
        }
    }

    /*
     * write a mariadb package to socket
     */
    protected func write(data: Array<Byte>) {
        socket.write(data)
    }

    /*
     * flsuh b
     */
    protected func flush() {
        socket.flush()
    }


}