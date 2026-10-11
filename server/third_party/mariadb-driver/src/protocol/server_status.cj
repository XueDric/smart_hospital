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

protected enum ServerStatus {

    | InTransaction
    | AutoCommit
    | MoreResults
    | NoGoodIndexUsed
    | NoIndexUsed
    | CursorExists
    | LastRowSend
    | DbDropped
    | NoBackslashEscapes
    | MetaDataChanged
    | QueryWasSlow
    | PsOutParams
    | InStransReadOnly
    | SessionStateChanged

    protected func value(): UInt16 {
        match (this) {
            case InTransaction => 1 << 0
            case AutoCommit => 1 << 1
            case MoreResults => 1 << 2
            case NoGoodIndexUsed => 1 << 3
            case NoIndexUsed => 1 << 4
            case CursorExists => 1 << 5
            case LastRowSend => 1 << 6
            case DbDropped => 1 << 7
            case NoBackslashEscapes => 1 << 8
            case MetaDataChanged => 1 << 9
            case QueryWasSlow => 1 << 10
            case PsOutParams => 1 << 11
            case InStransReadOnly => 1 << 12
            case SessionStateChanged => 1 << 13
        }
    }
}