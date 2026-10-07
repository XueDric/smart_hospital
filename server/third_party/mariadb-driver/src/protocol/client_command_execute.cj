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

import std.io.*

protected class ExecuteCommand <: Command {

    private let statementId: UInt32

    private let flags: CursorType

    private let iterationCount: UInt32

    private let parameterCount: UInt64

    private let nullBitMap: Array<Byte>

    private let newParamsBindFlag: UInt8

    private let params: Array<Any>

    private init(id: UInt32, flags: CursorType, iterationCount: UInt32, boundFlag: UInt8, params: Array<Any>) {
        super(CommandType.StmtExecute)
        this.statementId = id
        this.flags = flags
        this.iterationCount = iterationCount
        this.parameterCount = UInt64(params.size)
        this.nullBitMap = Array<Byte>((params.size + 7) / 8, repeat: 0)
        this.newParamsBindFlag = boundFlag
        this.params = params
    }

    public static func default(id: UInt32, params: Array<Any>): ExecuteCommand {
        return ExecuteCommand(id, NoCursor, 1, 1, params)
    }

    public static func withReadOnly(id: UInt32, params: Array<Any>): ExecuteCommand {
        return ExecuteCommand(id, ReadOnly, 1, 1, params)
    }

    public override func pack(): Unit {
        super.pack()
        // id
        this.statementId |> buffer.writeInt4
        // flag
        this.flags.value() |> buffer.writeInt1
        // iteration_count
        this.iterationCount |> buffer.writeInt4
        if (parameterCount > 0 || flags == ParameterCountAvailable) {
            if (HandshakeResponse.getDefault(0).hasCapability(QueryAttributes)) {
                //parameter_count
                this.parameterCount |> buffer.writeLengthEncoded
            }
            if (parameterCount > 0) {
                // null_bitmap
                for (i in 0..params.size) {
                    match (params[i]) {
                        case v: ?Any => 
                            if(v.isNone()) {
                                nullBitMap[(i / 8)] |= 1u8 << (i % 8)
                            }
                        case _ => continue
                    }
                }
                this.nullBitMap |> buffer.writeArray

                // new_params_bind_flag
                this.newParamsBindFlag |> buffer.writeInt1
                if (newParamsBindFlag == 1) {
                    //parameter_type
                    for(i in 0..params.size) {
                        match (params[i]) {
                            case v: NativeType => v.writeType(buffer)
                            case v: InputStream => [ColumnType.LongBlob.value(), 0x00] |> buffer.writeArray
                            case v: ?Any => [ColumnType.Null.value(), 0x00] |> buffer.writeArray
                            case _ => throw UnsupportedException("")
                        }
                    }
                    if (HandshakeResponse.getDefault(0).hasCapability(QueryAttributes)) {
                        0x00 |> buffer.writeInt1 //paramter name: default null
                    }
                }

                //parameter_values
                for (i in 0..params.size) {
                    match (params[i]) {
                        case v: NativeType => v.writeValue(buffer)
                        case _: InputStream => continue
                        case _: ?Any => continue
                        case _ => throw UnsupportedException("")
                    }
                }

            }
        }
    }
    
}