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


protected open class MariaException <: Exception & ToString {

    protected init() {
       super()
    }

    protected init(message: String) {
        super(message)    
    }

    public open func toString(): String {
        return "MariaException: ${message}"
    }

}


/*
* 无效数据包异常类,表示数据包解析异常
*/
protected class InvalidPacketException <: MariaException {

    init() {
       super()
    }

    protected init(message: String) {
        super(message)    
    }

    public func toString(): String {
        return "InvalidPacketException: ${message}"
    }

}
