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

import mariadb.protocol.*

protected class ChangeResult {
    
    protected let effectRow: UInt64

    protected let lastInsertId: UInt64

    public ChangeResult(effectRow: UInt64, lastInsertId: UInt64) {
        this.effectRow = effectRow
        this.lastInsertId = lastInsertId
    }

}

protected class PrepareResult {

    protected let info: PrepareResposne

    protected let params: Array<ColumnDefinition>

    protected let columns: Array<ColumnDefinition>

    protected PrepareResult(info: PrepareResposne, parameters: Array<ColumnDefinition>, columns: Array<ColumnDefinition>){
        this.info = info
        this.params = parameters
        this.columns = columns
    }

    protected prop id: UInt32 {
        get() {
            info.statementId
        }
    }

}
