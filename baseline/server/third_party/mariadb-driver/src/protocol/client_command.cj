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

protected abstract class Command <: Request {

    private let commandType: CommandType

    protected init(commandType: CommandType) {
        super(0)
        this.commandType = commandType
    }

    protected open override func pack(): Unit {
        this.commandType.value() |> buffer.writeInt1
    }

}


protected class QueryCommand <: Command {

    private let query: String

    protected init(query: String) {
        super(Query)
        this.query = query
    }

    protected override func pack(): Unit {
        super.pack()
        this.query |> buffer.writeString
    }

}

protected class PrepareCommand <: Command {

    private let sql: String

    protected init(sql: String) {
        super(StmtPrepare)
        this.sql = sql
    }

    public override func pack(): Unit{
        super.pack()
        this.sql |> buffer.writeString
    }

}


protected class FetchCommand <: Command {
    
    private let statementId: UInt32

    private let numRows: UInt32

    protected init(statementId: UInt32, numRows: UInt32){
        super(StmtFetch)
        this.statementId = statementId
        this.numRows = numRows
    }

    protected override func pack(): Unit {
        super.pack()
        this.statementId |> buffer.writeInt4
        this.numRows |> buffer.writeInt4
    }

}

protected class CloseCommand <: Command {

    private let statementId: UInt32

    protected init(id: UInt32){
        super(StmtClose)
        this.statementId = id
    }

    protected override func pack(): Unit {
        super.pack()
        this.statementId |> buffer.writeInt4
    }
}

protected class ResetCommand <: Command {

    private let statementId: UInt32

    internal init(statementId: UInt32){
        super(StmtReset)
        this.statementId = statementId
    }

    public override func pack(): Unit {
        super.pack()
        this.statementId |> buffer.writeInt4
    }
}


protected class SendLongDataCommand <: Command {

    private let statementId: UInt32

    private let parameterId: UInt16

    private let data: Array<Byte>

    protected init(statementId: UInt32, parameterId: UInt16, data: Array<Byte>) {
        super(StmtSendLongData)
        this.statementId = statementId
        this.parameterId = parameterId
        this.data = data
    }

    public override func pack(): Unit {
        super.pack()
        this.statementId |> buffer.writeInt4
        this.parameterId |> buffer.writeInt2
        this.data |> buffer.write
    }

}