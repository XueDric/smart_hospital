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

protected enum ColumnFlag {
    
    | NotNull
    | PrimaryKey
    | UniqueKey
    | MultipleKey
    | Blob
    | Unsigned
    | ZeroFill
    | Binary
    | Enum
    | AutoIncrement
    | Timestamp
    | Set
    | NoDefaultValue
    | OnUpdateNow
    | PartKey
    | Num

    internal func value(): UInt16 {
        match (this) {
            case NotNull => 1 << 0
            case PrimaryKey => 1 << 1
            case UniqueKey => 1 << 2
            case MultipleKey => 1 << 3
            case Blob => 1 << 4
            case Unsigned => 1 << 5
            case ZeroFill => 1 << 6
            case Binary => 1 << 7
            case Enum => 1 << 8
            case AutoIncrement => 1 << 9
            case Timestamp => 1 << 10
            case Set => 1 << 11
            case NoDefaultValue => 1 << 12
            case OnUpdateNow => 1 << 13
            case PartKey => 1 << 14
            case Num => 1 << 15
        }
    }
}