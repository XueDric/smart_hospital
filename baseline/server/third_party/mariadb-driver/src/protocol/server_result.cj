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

protected class ColumnCount <: CommonResponse {

    protected let count: UInt64

    protected init(length: UInt64, number: UInt8, buffer: ByteBuffer) {
        super(length, number)
        //列的数量: lenenc
        this.count = UInt64.fromLittleEndian(buffer.readLengthEncodedIntegerRaw().getOrThrow())
    }
}

protected class ColumnDefinition <: CommonResponse {
    /*目录名*/
    protected let catalog: String
    /*数据库名*/
    protected let database: String
    /*表名*/
    protected let table: String
    /*原始表名*/
    protected let originalTable: String
    /*字段名*/
    protected let name: String
    /*原始字段名*/
    protected let originalName: String
    /*填充值*/
    protected let padding: Byte
    /*字符串编码*/
    protected let charset: Charset
    /*字段长度*/
    protected let columnLength: UInt32
    /*字段类型*/
    protected let columnType: ColumnType
    /*字段标志*/
    protected let flags: UInt16
    /*浮点型精度*/
    protected let decimals: Byte

    protected init(length: UInt64, number: UInt8, buffer: ByteBuffer) {
        super(length, number)
        //目录名: lenenc
        this.catalog = buffer.readLengthEncodedString().getOrThrow()
        //数据库名: lenenc
        this.database = buffer.readLengthEncodedString().getOrThrow()
        //表别名: lenenc
        this.table = buffer.readLengthEncodedString().getOrThrow()
        //表名: lenenc
        this.originalTable = buffer.readLengthEncodedString().getOrThrow()
        //列别名: lenenc
        this.name = buffer.readLengthEncodedString().getOrThrow()
        //列名: lenenc
        this.originalName = buffer.readLengthEncodedString().getOrThrow()
        //保留位: 1 byte
        this.padding = buffer.readInt1()
        //字符集: 2 byte
        this.charset = Charset.of(buffer.readInt2())
        //字段最大长度: 4 byte
        this.columnLength = buffer.readInt4()
        //列类型: 1 byte
        this.columnType = ColumnType.of(buffer.readInt1())
        //列标志: 2 byte
        this.flags =buffer.readInt2()
        //精度: 1 byte
        this.decimals = buffer.readInt1()
    }

    protected func hasFlag(flag: ColumnFlag): Bool {
        (flags & flag.value()) != 0
    }
}

protected class TextResult <: CommonResponse {

    protected let row: Array<?Array<Byte>>

    protected init(length: UInt64, number: UInt8, buffer: ByteBuffer, columnCount: Int64) {
        super(length, number)
        this.row = Array<?Array<Byte>>(columnCount, repeat: None)
        for(i in 0..columnCount) {
            row[i] = buffer.readLengthEncodedStringRaw()
        }
    }
}

protected class BinaryResult <: Response {
    
    protected let nullMap: Array<Byte>

    protected let row: Array<?Array<Byte>>

    protected init(length: UInt64, number: UInt8, buffer: ByteBuffer, columnInfos: Array<ColumnDefinition>) {
        super(length, number, buffer)
        let columnCount = columnInfos.size
        //null数据位图
        let size = (columnCount + 7 + 2) / 8
        this.nullMap = buffer.readArray(size)
        //二进制数据
        this.row = Array<?Array<Byte>>(columnCount, repeat: [])
        for (i in 0..columnCount){
            let isNull = (nullMap[(i + 2) / 8] & (1u8 << ((i + 2) % 8))) != 0
            if (isNull) {
                row[i] = None
            } else {
                let columnInfo = columnInfos[i] 
                let columnType = columnInfo.columnType
                match (columnType) {
                    case Null => continue
                    case Tiny =>
                        row[i] = buffer.readArray(1)
                    case Short | Year =>
                        row[i] = buffer.readArray(2)
                    case Long | Int24 | Float =>
                        row[i] = buffer.readArray(4)
                    case LongLong | Double =>
                        row[i] = buffer.readArray(8)
                    case String | NewDecimal | Json | Enum | Set | TinyBlob | MediumBlob | LongBlob | Blob | VarString | Bit =>
                         row[i] = buffer.readLengthEncodedStringRaw()
                    case Date | DateTime | Timestamp | Time =>
                        let flag = buffer.readInt1()
                        row[i] = buffer.readArray(Int64(flag))
                }
            }
        }
    }
}
