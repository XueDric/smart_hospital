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

import std.io.*
import std.net.*
import std.sync.*
import std.collection.*
import mariadb.protocol.*

/**
* The mariadb connection object facilitates the upper-layer driver to interact with the database
*/
protected class MariaConnection <: Resource {
    
    private let mutex: Mutex = Mutex()

    private var channel: MariaChannel

    internal init(socket: TcpSocket) {
        this.channel = MariaChannel(socket)
    }

    protected prop connectionMutex: Mutex {
        get() {
            mutex
        }
    }

    protected mut prop socket: StreamingSocket {
        get() {
            channel.socket
        }
        set(value) {
            channel.socket = value
        }
    }

    protected func read(): (UInt64, UInt8, ByteBuffer) {
        return channel.read()
    }

    protected func write(data: Array<Byte>): Unit {
        return channel.write(data)
    }

    protected func flush(): Unit {
        return channel.flush()
    }

    public override func close() {
        synchronized(connectionMutex){
            checkResourceAvailability()
            writeRequest(QuitCommand())
            channel.close()
        }
    }

    public override func isClosed(): Bool {
        return channel.isClosed()
    }

    /**
    * send a command to mariadb server, like BEGIN or COMMIT statemnt without returned value
    * @throws ResponseErrorException
    */
    protected func sendCommand(sql: String): Unit {
        synchronized(connectionMutex) {
            writeRequest(QueryCommand(sql))
            readOkResponse()
        }
    }

    /**
    * send a query statment to mariadb server
    * @return ResultSet
    * @throw ResponseErrorException
    */
    protected func sendQuery(sql: String): ResultSet {
        synchronized(connectionMutex) {
            writeRequest(QueryCommand(sql))
            return readQueryResponse()
        }
    }

    /**
    * send a update statemnt to mariadb server
    * @return ChangeResult
    * @throw ResponseErrorException
    */
    protected func sendUpdate(sql: String): ChangeResult {
        synchronized(connectionMutex) {
            writeRequest(QueryCommand(sql))
            let count = countSqlStatements(sql)
            if(count > 1) {
                for(_ in 0..count) {
                    readOkResponse()
                }
                return ChangeResult(0, 0)
            }
            return readUpdateResponse()
        }
    }

    /**
    * send a prepare statement to mariadb server
    * @return PrepareResult
    * @throw ResponseErrorException
    */
    protected func sendPrepare(sql: String): PrepareResult {
        synchronized(connectionMutex) {
            writeRequest(PrepareCommand(sql))
            return readPrepareResponse()
        }
    }

    /**
    * execute prepare statement of the query type, all result sets from the query will be returned
    * @param prepare: PrepareResult 
    * @param params: Array<Any> 
    * @result ResultSet 
    * @throws ResponseErrorException
    */
    protected func executeQueryPrepare(statementId: UInt32, params: Array<Any>): ResultSet {
        synchronized(connectionMutex) {
            handleLongData(statementId, params)
            writeRequest(ExecuteCommand.default(statementId, params))
            return readQueryPrepareResponse()
        }
    }

    /**
    * execute prepare statemnt of the query type, it's will using cursors to fetch result set
    * @param prepare: PrepareResult 
    * @param params: Array<Any> 
    * @result ResultSet 
    * @throws ResponseErrorException
    */
    protected func executeQueryPrepareWithCursor(statementId: UInt32, params: Array<Any>, fetchSize: UInt32): ResultSet {
        synchronized(connectionMutex) {
            handleLongData(statementId, params)
            writeRequest(ExecuteCommand.withReadOnly(statementId, params))
            return readQueryPrepareResponseWithCursor(statementId, fetchSize)
        }
    }

    /**
    * execute prepare statemnt of the update type
    * @param prepare: PrepareResult
    * @param params: Array<Any>
    * @result ResultSet
    * @throws ResponseErrorException
    */
    protected func executeUpdatePrepare(prepare: PrepareResult, params: Array<Any>): ChangeResult {
        synchronized(connectionMutex) {
            handleLongData(prepare.id, params)
            writeRequest(ExecuteCommand.default(prepare.id, params))
            return readUpdateResponse()
        }
    }

    /*
    * fetch some result set from prepare statemnt
    * @param prepareId: UInt32
    * @param fetchSize: UInt32
    */
    protected func fetchRows(prepareId: UInt32, columnInfos: Array<ColumnDefinition>, fetchSize: UInt32): ResultSet {
        synchronized(connectionMutex) {
            writeRequest(FetchCommand(prepareId, fetchSize))
            try {
                return readFetchResponse(columnInfos)
            }catch (e: ResponseErrorException) {
                return BinaryResultSet(columnInfos, [])
            }
        }
    }


    /**
    * close prepare statement
    * @param id: UInt32 预编译语句id
    */
    protected func closePrepare(id: UInt32): Unit {
        synchronized(connectionMutex) {
            writeRequest(CloseCommand(id))
        }
    } 

    protected func createTransaction(): MariaTransaction {
        return MariaTransaction(this)
    }

    private func handleLongData(statementId: UInt32, params: Array<Any>){
        for (i in 0..params.size) {
            let param = params[i]
            match (param) {
                case v: InputStream => writeRequest(SendLongDataCommand(statementId, UInt16(i), toArray(v)))
                case _ => continue
            }
        }
    }


    /*
     * read response of prepare statemnt
     */
    private func readPrepareResponse(): PrepareResult {
        let (length, number, payload) = read()
        checkErrorResponse(length, number, payload)
        let prepareResponse = PrepareResposne(length, number, payload)
        let parameters = ArrayList<ColumnDefinition>(Int64(prepareResponse.numParams))
        if(prepareResponse.numParams > 0) {
            for (_ in 0..prepareResponse.numParams) {
                let (length, number, payload) = read()
                parameters.add(ColumnDefinition(length, number, payload))
            }
            read()
        }
        let columns = ArrayList<ColumnDefinition>(Int64(prepareResponse.numColumns))
        if(prepareResponse.numColumns > 0) {
            for (_ in 0..prepareResponse.numColumns) {
                let (length, number, payload) = read()
                columns.add(ColumnDefinition(length, number, payload))
            }
            read()
        }
        return PrepareResult(prepareResponse, parameters.toArray(), columns.toArray())
    }

    /*
    * read response of execute query prepare statemnt
    */
    private func readQueryPrepareResponse(): ResultSet {
        var (length, number, payload) = read()
        checkErrorResponse(length, number, payload)
        checkInexpectantOkResponse(payload)
        let filedsCount = ColumnCount(length, number, payload)
        let fields = ArrayList<ColumnDefinition>()
        for (_ in 0..filedsCount.count) {
            let (length, number, payload) = read()
            let field = ColumnDefinition(length, number, payload)
            fields.add(field)
        }
        //丢弃Eof包
        read()
        (length, number, payload) = read()
        let rows = ArrayList<BinaryResult>()
        while (payload.bytes()[0] != ResponseCode.Eof.value() || payload.bytes().size > 5) {
            let row = BinaryResult(length, number, payload, fields.toArray())
            rows.add(row)
            (length, number, payload) = read()
        }
        return BinaryResultSet(fields.toArray(), rows.toArray())
    }

    /*
    * read response of fetch result set
    */
    private func readFetchResponse(columnInfos: Array<ColumnDefinition>): ResultSet {
        var (length, number, payload) = read()
        checkErrorResponse(length, number, payload)
        let rows = ArrayList<BinaryResult>()
        while (payload.bytes()[0] != ResponseCode.Eof.value() || payload.bytes().size > 5) {
            let row = BinaryResult(length, number, payload, columnInfos)
            rows.add(row)
            (length, number, payload) = read()
        }
        return BinaryResultSet(columnInfos, rows.toArray())
    }

    /*
    * read response of execute query prepare with cursor
    */
    private func readQueryPrepareResponseWithCursor(prepareId: UInt32, fetchSize: UInt32): ResultSet {
        let (length, number, payload) = read()
        checkErrorResponse(length, number, payload) 
        let filedsCount = ColumnCount(length, number, payload)
        let fields = ArrayList<ColumnDefinition>()
        for (_ in 0..filedsCount.count) {
            let (length, number, payload) = read()
            let field = ColumnDefinition(length, number, payload)
            fields.add(field)
        }
        //drop eof package
        read()
        return CursorResultSet(prepareId, fields.toArray(), fetchSize ,this)
    }


    /*
     * read handshake package
     */
    internal func readHandhake(): Handshake {
        let (length, number, payload) = read()
        return Handshake(length, number, payload)
    }

    /*
     * read a response, maybe OkResponse,ErrorResponse,AbstructEof,AuthStateResponse or it's subclass
     */
    internal func readResponse(): Response {
        let (length, number, payload) = read()
        let code = ResponseCode.of(payload.bytes()[0])
        match (code) {
            case ResponseCode.Ok =>
                return OkResponse(length, number, payload)
            case ResponseCode.Error =>
                return ErrorResponse(length, number, payload)
            case ResponseCode.Eof => return getEofResponse(length, number, payload)
            case ResponseCode.AuthMoreData => return getAuthMoreData(length, number, payload)
        }
    }

    private func getEofResponse(length: UInt64, number: UInt8, payload: ByteBuffer): AbstractEOF {
        if (payload.bytes().size > 8) {
            return AuthSwitch(length, number, payload)
        } else {
            return EofResponse(length, number, payload)
        }
    }

    private func getAuthMoreData(length: UInt64, number: UInt8, payload: ByteBuffer): AuthMoreData {
        let authCode = payload.bytes()[1]
        if (payload.bytes().size == 2 && (authCode == AuthState.FastAuthSuccess.value() || authCode == AuthState.PerformFullAuthentication.value())) {
            return AuthStatus(length, number, payload)
        } else {
            return PublicKeyResponse(length, number, payload)
        }
    }

    internal func writeRequest(request: Request): Unit {
        request.writeTo(channel.socket)
        flush()
    }


    private func readOkResponse(): OkResponse {
        match (readResponse()) {
            case error: ErrorResponse => throw ResponseErrorException(error.message)
            case ok: OkResponse => ok
            case other => throw MariaException("Inexpect response: ${other.code}")
        }
    }

    /*
     * handler response of execute update
     */
    private func readUpdateResponse(): ChangeResult {
        let ok = readOkResponse()
        return ChangeResult(ok.effectRows, ok.index)
    }

    /*
     * handler response of execute query
     */
    private func readQueryResponse(): TextResultSet {
        var (length, number, payload) = read()
        checkErrorResponse(length, number, payload)
        checkInexpectantOkResponse(payload)
        let columnCount = ColumnCount(length, number, payload)
        let fields = ArrayList<ColumnDefinition>()
        for (_ in 0..columnCount.count) {
            let (length, number, payload) = channel.read()
            let field = ColumnDefinition(length, number, payload)
            fields.add(field)
        }
        //丢弃Eof包
        read()
        (length, number, payload) = read()
        let rowPackets = ArrayList<TextResult>()
        while (payload.bytes()[0] != ResponseCode.Eof.value() || payload.bytes().size > 5) {
            let row = TextResult(length, number, payload, Int64(columnCount.count))
            rowPackets.add(row)
            (length, number, payload) = channel.read()
        }
        return TextResultSet(fields.toArray(), rowPackets.toArray())
    }

    private func checkInexpectantOkResponse(payload: ByteBuffer) {
        if(payload.bytes()[0] == ResponseCode.Ok.value()) {
            throw MariaException("Execute non-select statements using the query method.")
        }
    }

    private func checkErrorResponse(length: UInt64, number: UInt8, payload: ByteBuffer) {
        if (payload.bytes()[0] == ResponseCode.Error.value()) {
            let error = ErrorResponse(length, number, payload)
            throw ResponseErrorException(error.message)
        }
    }

    private func checkResourceAvailability() {
        if (isClosed()) {
            throw Exception("The database Connection has been closed")
        }
    }

    private func countSqlStatements(sql: String): Int64 {
        //后续替换更安全的算法
        return sql.split(";", removeEmpty: true).size
    }

}
