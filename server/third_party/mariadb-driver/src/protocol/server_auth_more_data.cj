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

protected open class AuthMoreData <: Response {

    /*
     * 认证响应数据: 可能是一个字节的数据,表示执行的是fast auth还是执行full auth
     * 也可能是执行full auth 返回的服务器公钥
     */
    internal var authRep: Array<Byte>

    internal init(length: UInt64, number: UInt8, buffer: ByteBuffer) {
        super(length, number, buffer)
        this.authRep = buffer.readArray(Int64(length - 1))
    }

}

/*
* 公钥响应报文
*/
protected class PublicKeyResponse <: AuthMoreData {

    protected prop publicKey: String {
        get() {
            return String.fromUtf8(authRep)
        }
    }

    protected init(length: UInt64, number: UInt8, buffer: ByteBuffer) {
        super(length, number, buffer)
    }
}

/*
* 认证状态响应报文
*/
protected class AuthStatus <: AuthMoreData {

    protected prop state: AuthState {
        get() {
            AuthState.of(authRep[0])
        }
    }

    protected init(length: UInt64, number: UInt8, buffer: ByteBuffer) {
        super(length, number, buffer)
    }
    
}