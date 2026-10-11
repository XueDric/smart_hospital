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
package mariadb.cdbc

import std.database.sql.*
import mariadb.protocol.*

public class ColumnInfoImpl <: ColumnInfo {

    private let colName: String

    private let colType: String

    private let colSize: Int64

    private let colLength: Int64

    private let colScale: Int64

    private let colNullable: Bool

    protected init(definition: ColumnDefinition) {
        let unsigned = definition.hasFlag(Unsigned)
        this.colName = definition.name
        this.colType = definition.columnType.cangjieType(unsigned)
        this.colSize = Int64(definition.columnLength)
        this.colLength = Int64(definition.columnLength)
        this.colScale = Int64(definition.decimals)
        this.colNullable = !definition.hasFlag(NotNull)
    }

    public override prop name: String {
        get() {
            return colName
        }
    }

    public override prop typeName: String {
        get() {
            return colType
        }
    }

    public override prop displaySize: Int64 {
        get() {
            return colSize
        }
    }

    public override prop length: Int64 {
        get() {
            return colLength
        }
    }

    public override prop scale: Int64 {
        get() {
            return colScale
        }
    }

    public override prop nullable: Bool {
        get() {
            return colNullable
        }
    }
}
