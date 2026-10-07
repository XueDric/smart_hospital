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

import std.io.*
import std.time.*
import std.math.numeric.*
import mariadb.connection.*

public interface SqlParameter {

    func asParameter(): String

}

extend ?Any <: SqlParameter {

    public func asParameter(): String {
        if (this.isNone()) {
            return "NULL"
        } else {
            return ""
        }
    }

}

extend Bool <: SqlParameter {

    public func asParameter(): String {
        if (this) {
            return "1"
        }else {
            return "0"
        }
    }

}

extend Int8 <: SqlParameter {

    public func asParameter(): String {
        return this.toString()
    }

}

extend UInt8 <: SqlParameter {

    public func asParameter(): String {
        return this.toString()
    }

}

extend Int16 <: SqlParameter {
    public func asParameter(): String {
        return this.toString()
    }
}

extend UInt16 <: SqlParameter {
    public func asParameter(): String {
        return this.toString()
    }
}

extend Int32 <: SqlParameter {
    public func asParameter(): String {
        return this.toString()
    }
}

extend UInt32 <: SqlParameter {
    public func asParameter(): String {
        return this.toString()
    }
}

extend Int64 <: SqlParameter {
    public func asParameter(): String {
        return this.toString()
    }
}

extend UInt64 <: SqlParameter {
    public func asParameter(): String {
        return this.toString()
    }
}

extend Float16 <: SqlParameter {
    public func asParameter(): String {
        return this.toString()
    }
}

extend Float32 <: SqlParameter {
    public func asParameter(): String {
        return this.toString()
    }
}

extend Float64 <: SqlParameter {
    public func asParameter(): String {
        return this.toString()
    }
}

extend ByteBuffer <: SqlParameter {

    public func asParameter(): String {
        return toHexStringWithPrefix(this)
    }
    
}

extend Array<Byte> <: SqlParameter {

    public func asParameter(): String {
        return toHexStringWithPrefix(this)
    }

}

extend String <: SqlParameter {

    public func asParameter(): String {
        return escapeString(this)
    }

}

extend DateTime <: SqlParameter {

    public func asParameter(): String {
        return "'" + this.format(DB_DATE_TIME_FORMAT) + "'"
    }

}

extend BigInt <: SqlParameter {

    public func asParameter(): String {
        return "'" + this.toString() + "'"
    }

}

extend Decimal <: SqlParameter {

    public func asParameter(): String {
        return "'" + this.toString() + "'"
    }

}

