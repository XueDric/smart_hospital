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

protected enum CommandType {
    | Sleep
    | Quit
    | InitDB
    | Query
    | FieldList
    | CreateDB
    | DropDB
    | Refresh
    | Shutdown
    | Statistics
    | ProcessInfo
    | Connect
    | ProcessKill
    | Debug
    | Ping
    | Time
    | DelayedInsert
    | ChangeUser
    | BinLogDump
    | TableDump
    | ConnectOut
    | StmtRegisterSlave
    | StmtPrepare
    | StmtExecute
    | StmtSendLongData
    | StmtClose
    | StmtReset
    | SetOption
    | StmtFetch
    | Daemon
    | BinLogDumpGTID
    | ResetConnection
    | Clone 
    | SubscribeGroupReplicationStream

    public func value(): Byte {
        match(this) {
            case Sleep => 0x00
            case Quit => 0x01
            case InitDB => 0x02
            case Query => 0x03
            case FieldList => 0x04
            case CreateDB => 0x05
            case DropDB => 0x06
            case Refresh => 0x07
            case Shutdown => 0x08
            case Statistics => 0x09
            case ProcessInfo => 0x0A
            case Connect => 0x0B
            case ProcessKill => 0x0C
            case Debug => 0x0D
            case Ping => 0x0E
            case Time => 0x0F
            case DelayedInsert => 0x10
            case ChangeUser => 0x11
            case BinLogDump => 0x12
            case TableDump => 0x13
            case ConnectOut => 0x14
            case StmtRegisterSlave => 0x15
            case StmtPrepare => 0x16
            case StmtExecute => 0x17
            case StmtSendLongData => 0x18
            case StmtClose => 0x19
            case StmtReset => 0x1A
            case SetOption => 0x1B
            case StmtFetch => 0x1C
            //uncheck
            case Daemon => 0x1D
            case BinLogDumpGTID => 0x1E
            case ResetConnection => 0x1F
            case Clone => 0x20
            case SubscribeGroupReplicationStream => 0x21
        }
    }

    public static func of(value: Byte): CommandType {
        match(value) {
            case 0x00 => Sleep
            case 0x01 => Quit
            case 0x02 => InitDB
            case 0x03 => Query
            case 0x04 => FieldList
            case 0x05 => CreateDB
            case 0x06 => DropDB
            case 0x07 => Refresh
            case 0x08 => Shutdown
            case 0x09 => Statistics
            case 0x0A => ProcessInfo
            case 0x0B => Connect
            case 0x0C => ProcessKill
            case 0x0D => Debug
            case 0x0E => Ping
            case 0x0F => Time
            case 0x10 => DelayedInsert
            case 0x11 => ChangeUser
            case 0x12 => BinLogDump
            case 0x13 => TableDump
            case 0x14 => ConnectOut
            case 0x15 => StmtRegisterSlave
            case 0x16 => StmtPrepare
            case 0x17 => StmtExecute
            case 0x18 => StmtSendLongData
            case 0x19 => StmtClose
            case 0x1A => StmtReset
            case 0x1B => SetOption
            case 0x1C => StmtFetch
            case 0x1D => Daemon
            case 0x1E => BinLogDumpGTID
            case 0x1F => ResetConnection
            case 0x20 => Clone
            case 0x21 => SubscribeGroupReplicationStream
            case _ => throw Exception("Don't have this CommandType by value: ${value}")
        }
    }
}