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



/*
* 服务器响应Error异常,表示执行命令后服务器响应Error
*/
protected class ResponseErrorException <: MariaException {

    init() {
        super()
    }

    protected ResponseErrorException(message: String) {
        super(message)    
    }

    public func toString(): String {
        return "ResponseErrorException: ${message}"
    }

}

/*
*  连接失败异常
*/
protected class ConnectFailedException <: MariaException {

    init() {
        super()
    }

    protected ConnectFailedException(message: String) {
        super(message)    
    }

    public func toString(): String {
        return "ConnectFailedException: ${message}"
    }

}

/*
* 值转换异常
*/
protected class ValueConvertException <: Exception {
    init() {
       super()
    }

    init(message: String) {
        super(message)    
    }

}