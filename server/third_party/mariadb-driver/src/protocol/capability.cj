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

protected enum Capability {

    | LongPassword
    | FoundRows
    | LongFlags
    | ConnectWithDB
    | NoSchema
    | Compress
    | ODBC
    | LocalFiles
    | IgnoreSpace
    | Protocol41
    | Interactive
    | SSL
    | IgnoreSigpipe
    | Transactions
    | Reserved
    | Reserved2
    | MultiStatements
    | MultiResults
    | PsMultiResults
    | PluginAuth
    | ConnectAttrs
    | PluginAuthLenencClientData
    | CanHandleExpiredPasswords
    | SessionTrack
    | DeprecateEOF
    | OptionalResultSetMetadata
    | ZSTDCompressionAlgorithm
    | QueryAttributes
    | MultiFactorAuthentication
    | CapabilityExtension
    | SSLVerifyServerCert
    | RememberOptions

    internal func value(): UInt32 {
        match (this) {
            case LongPassword => 1 << 0
            case FoundRows => 1 << 1
            case LongFlags => 1 << 2
            case ConnectWithDB => 1 << 3
            case NoSchema => 1 << 4
            case Compress => 1 << 5
            case ODBC => 1 << 6
            case LocalFiles => 1 << 7
            case IgnoreSpace => 1 << 8
            case Protocol41 => 1 << 9
            case Interactive => 1 << 10
            case SSL => 1 << 11
            case IgnoreSigpipe => 1 << 12
            case Transactions => 1 << 13
            case Reserved => 1 << 14
            case Reserved2 => 1 << 15
            case MultiStatements => 1 << 16
            case MultiResults => 1 << 17
            case PsMultiResults => 1 << 18
            case PluginAuth => 1 << 19
            case ConnectAttrs => 1 << 20
            case PluginAuthLenencClientData => 1 << 21
            case CanHandleExpiredPasswords => 1 << 22
            case SessionTrack => 1 << 23
            case DeprecateEOF => 1 << 24
            case OptionalResultSetMetadata => 1 << 25
            case ZSTDCompressionAlgorithm => 1 << 26
            case QueryAttributes => 1 << 27
            case MultiFactorAuthentication => 1 << 28
            case CapabilityExtension => 1 << 29
            case SSLVerifyServerCert => 1 << 30
            case RememberOptions => 1 << 31
        }
    }

}

protected class DefaultCapability {

    protected static var default: UInt32 = 0

    protected static func set(capability: Capability) {
        default |= capability.value()
    }

    protected static func has(capability: Capability): Bool {
        return (default & capability.value()) != 0
    }

    static init() {
        set(LongPassword)
        set(LongFlags)
        set(LocalFiles)
        set(Protocol41)
        set(Interactive)
        set(Transactions)
        set(MultiStatements)
        set(MultiResults)
        set(PluginAuth)
        set(ConnectAttrs)
        set(PluginAuthLenencClientData)
        set(CanHandleExpiredPasswords)
        set(SessionTrack)
        set(RememberOptions)
        set(Reserved2)
    }

}