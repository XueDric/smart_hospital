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

protected open class CommonResponse {

    protected let length: UInt64

    protected let number: UInt8

    internal init(length: UInt64, number: UInt8) {
        this.length = length
        this.number = number
    }

}

protected open class Response <: CommonResponse {

    protected let code: ResponseCode

    protected init(length: UInt64, number: UInt8, buffer: ByteBuffer) {
        super(length, number)
        code = ResponseCode.of(buffer.readInt1())
    }

}

protected class OkResponse <: Response {

    protected let effectRows: UInt64

    protected let index: UInt64

    protected let serverStatus: UInt16

    protected let warningCount: UInt16

    //protected let message: String

    //protected let sessionInfo: String

    protected init(length: UInt64, number: UInt8, buffer: ByteBuffer) {
        super(length, number, buffer)
        //受影响的行: lenenc byte
        this.effectRows = UInt64.fromLittleEndian(buffer.readLengthEncodedIntegerRaw().getOrThrow())
        //最后一个插入的ID: lenenc byte
        this.index = buffer.readLengthEncodedInteger().getOrThrow()
        //服务器状态: 2 byte
        this.serverStatus = buffer.readInt2()
        //警告数量: 2 byte
        this.warningCount = buffer.readInt2()
        //this.message = ""
        //this.sessionInfo = ""
        // if(DefaultCapability.has(SessionTrack)) {
        //     this.message = buffer.readLengthEncodedString().getOrThrow()
        //     if(hasStatus(SessionStateChanged)) {
        //         this.sessionInfo = buffer.readLengthEncodedString().getOrThrow()
        //     }
        // }else {
        //     message = String.fromUtf8(buffer.readBytes(Int64(length - 5)))
        // }
        
    }

    protected func hasStatus(status: ServerStatus): Bool {
        return (serverStatus & status.value()) != 0
    }
}


protected class ErrorResponse <: Response {

    protected let errorCode: UInt16

    protected let serverStatusFlag: Byte

    protected let sqlStatus: Array<Byte>

    protected let message: String

    protected init(length: UInt64, number: UInt8, buffer: ByteBuffer) {
        super(length, number, buffer)
        //错误代码: 2 byte
        this.errorCode = buffer.readInt2()
        //SQL状态标记: 1 byte
        this.serverStatusFlag = buffer.readInt1()
        //SQL状态: 5 byte
        this.sqlStatus = buffer.readArray(5)
        //错误信息: rest byte
        this.message = buffer.readString(Int64(length - 9))
    }

}

protected open class AbstractEOF <: Response {

    protected init(length: UInt64, number: UInt8, buffer: ByteBuffer) {
        super(length, number, buffer)
    }
    
}

/*
* 切换认证方式响应报文
*/
protected class AuthSwitch <: AbstractEOF {

    protected let pluginName: String

    protected let salt: Array<Byte>

    protected init(length: UInt64, number: UInt8, buffer: ByteBuffer) {
        super(length, number, buffer)
        //插件名称: null end
        this.pluginName = buffer.readNullTerminatedString()
        //插件提供的数据: null end
        this.salt= buffer.readNullTerminatedStringRaw()
    }

}

/*
* 普通Eof响应报文
*/
protected class EofResponse <: AbstractEOF {

    protected let warningCount: UInt16

    protected let status: UInt16

    protected init(length: UInt64, number: UInt8, buffer: ByteBuffer) {
        super(length, number, buffer)
        //警告数量: 2 byte
        this.warningCount = buffer.readInt2()
        //状态标志
        this.status = buffer.readInt2()
    }

}

protected class PrepareResposne <: Response {

    protected let statementId: UInt32

    protected let numColumns: UInt16

    protected let numParams: UInt16

    protected let reserved: UInt8

    protected let warningCount: UInt16

    protected init(length: UInt64, number: UInt8, buffer: ByteBuffer) {
        super(length, number, buffer)
        //语句id: 4 byte
        this.statementId = buffer.readInt4()
        //列的数量: 2 byte
        this.numColumns = buffer.readInt2()
        //参数的数量: 2 byte
        this.numParams = buffer.readInt2()
        //保留位: 1 byte
        this.reserved = 0x00
        //警告数量
        if(length > 12) {
            this.warningCount = buffer.readInt2()
        }else {
            this.warningCount = 0
        }
    }

}