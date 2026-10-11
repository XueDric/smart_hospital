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

protected enum Charset {
    
    | Binary
    | Utf8mb3
    | Utf8mb4

    protected static func of(value: UInt16): Charset {
        match (value) {
            case 63 => Binary
            case 33 | 83 | 223 | 1057 | 1107 | 1216 | 1238  => Utf8mb3
            case 45 | 46 | 1069 | 1070 | 1248 | 1270 => Utf8mb4
            case range where range >= 192 && range <= 215 => Utf8mb3
            case range where range >= 224 && range <= 309 => Utf8mb4
            case range where range >= 576 && range <= 579 => Utf8mb3
            case range where range >= 608 && range <= 611 => Utf8mb4
            case _=> throw UnsupportedException("Unsupported Charset: ${value}")
        }
    }
    
}