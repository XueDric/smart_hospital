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

protected func insertCount(sql: String): Int {
    let lower = sql.toAsciiLower()
    let index = lower.indexOf("values") ?? throw SqlException()
    let values = lower[index + "values".size..lower.size]
    var depth = 0
    var count = 0
    for(i in values.runes()) {
        if(i == r'(') {
            depth ++
            if(depth == 1) {
                count ++
            }
        }else if(i == r')') {
            depth --
        }
    }
    return count
}
