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


/*
 * 认证状态枚举
 */
protected enum AuthState {
    
    | FastAuthSuccess
    | PerformFullAuthentication

    public static func of(value: Byte): AuthState {
        match (value) {
            case 0x03 => FastAuthSuccess
            case 0x04 => PerformFullAuthentication
            case _ => throw IllegalArgumentException("Don't have this AuthState by value ${value}")
        }
    }

    public func value(): Byte {
        match (this) {
            case FastAuthSuccess => 0x03
            case PerformFullAuthentication => 0x04
        }
    }

    public operator func ==(right: AuthState): Bool {
        return right.value() == this.value()
    }
}

/*
 * 响应码枚举
 */
protected enum ResponseCode <: ToString {

    | Ok
    | AuthMoreData
    | Eof
    | Error

    public func value(): Byte {
        match (this) {
            case Ok => 0x00
            case AuthMoreData => 0x01
            case Eof => 0xFE
            case Error => 0xFF
        }
    }
    
    public static func of(value: Byte): ResponseCode {
        match (value) {
            case 0x00 => Ok
            case 0xFF => Error
            case 0xFE => Eof
            case 0x01 => AuthMoreData
            case _ => throw MariaException("Inexpect response code: ${value}")
        }
    }

    public operator func ==(right: ResponseCode): Bool {
        return right.value() == this.value()
    }

    public func toString(): String {
        match (this) {
            case Ok => "Ok"
            case Error => "Error"
            case Eof => "Eof"
            case AuthMoreData => "AuthMoreData"
        }
    }
}

protected enum CursorType {

    | NoCursor
    | ReadOnly
    | ForUpdate
    | Scrollable
    | ParameterCountAvailable

    internal func value(): Byte {
        match (this) {
            case NoCursor => 0x00
            case ReadOnly => 0x01
            case ForUpdate => 0x02
            case Scrollable => 0x04
            case ParameterCountAvailable => 0x08
        }
    }

    internal operator func ==(right: CursorType): Bool {
        return this.value() == right.value()
    }
}

protected enum StatementOption {

    | MultiStatementsOn
    | MultiStatementsOff

    internal func value(): UInt16 {
        match (this) {
            case MultiStatementsOn => 0x00
            case MultiStatementsOff => 0x01
        }
    }
}
