<div align="center">
<h1>mariadb-driver</h1>
</div>
<p align="center">
<img alt="" src="https://img.shields.io/badge/release-v1.0.0-brightgreen" style="display: inline-block;" />
<img alt="" src="https://img.shields.io/badge/cjc-v1.0.0-brightgreen" style="display: inline-block;" />
</p>



## <img alt="" src="./doc/readme-image/readme-icon-introduction.png" style="display: inline-block;" width=3%/> 1 介绍

### 1.1 项目特性

mariadb-driver是使用Cangjie编写的mariadb原生驱动程序，适配MySQL、TIDB、OceanBase等数据库。

**ORM框架**：[CORM](https://gitcode.com/Yesokim/corm)

## <img alt="" src="./doc/readme-image/readme-icon-framework.png" style="display: inline-block;" width=3%/> 2 架构

### 2.1 项目结构

```shell
├── doc
    └── readme-image
└── src
    ├── cdbc 		
    ├── connection 	
    ├── protocol 	
    ├── result 		
    ├── test 	
    └── xa      
├── CHANGELOG
├── cjpm.lock
├── cjpm.toml
├── LICENSE
├── README.md
```

### 2.2 接口说明

> 参考仓颉官方的数据库接口文档

## <img alt="" src="./doc/readme-image/readme-icon-compile.png" style="display: inline-block;" width=3%/> 3 使用说明

> 仓颉提供的摘要算法和加密算法依赖OpenSSL3的crypto 动态库文件, 因此使用该驱动时需要确保本地环境有相应的动态库文件。
>
> windows openSSL预编译包下载 -> https://slproweb.com/products/Win32OpenSSL.html

### 3.1 编译构建（Win/Linux/Mac）

cjpm.toml文件添加以下配置后，再执行cjpm update，即可在项目中引入mariadb-driver。（需要额外设置环境变量CANGJIE_STDX_PATH，值为stdx的路径）
```tex
$ echo $CANGJIE_STDX_PATH
C:\Users\30247\Desktop\Cangjie\Cangjie-1.0.0\cangjie-stdx-windows-x64-1.0.0.1\windows_x86_64_llvm\static\stdx
```

```toml
[dependencies]
  mariadb = {git = "https://gitcode.com/Cangjie-SIG/mariadb-driver.git", branch="master"}
```

### 3.2 功能示例

```sql
CREATE TABLE `simple` (
`id` int NOT NULL AUTO_INCREMENT,
`varchar_col` varchar(255) DEFAULT NULL,
`int_col` int DEFAULT NULL,
`double_col` double(10,4) DEFAULT NULL,
`decimal_col` decimal(10,5) DEFAULT NULL,
`date_col` date DEFAULT NULL,
`time_col` time DEFAULT NULL,
`datetime_col` datetime DEFAULT NULL,
PRIMARY KEY (`id`)
) 
```

####  查询数据(Query)

```cangjie
import std.time.*
import std.math.numeric.*
import std.database.sql.*
import mariadb.cdbc.*

main(): Unit {
    var driver = DriverManager.getDriver("mariadb").getOrThrow()
    var property1 = ("username", "test_user")
    var property2 = ("password", "test_user")
    var property3 = ("database", "driver_test")
    var dataSource = driver.open("mariadb://localhost", [property1, property2, property3])
    var connection = dataSource.connect()
    var statemnt = connection.prepareStatement("select * from simple")
    var result = statemnt.query()
    while (result.next()) {
        result.get<UInt64>(1) |> println
        result.getOrNull<String>(2) |> println
        result.getOrNull<Int32>(3) |> println
        result.getOrNull<Float64>(4) |> println
        result.getOrNull<Decimal>(5) |> println
        result.getOrNull<DateTime>(6) |> println
        result.getOrNull<DateTime>(7) |> println
        result.getOrNull<DateTime>(8) |> println
    }
    
}
```

#### 更新数据(Insert、Update、Delete)

```cangjie
import std.database.sql.*
import mariadb.cdbc.*
import std.time.DateTime
import std.math.numeric.Decimal

main(): Unit {
    var driver = DriverManager.getDriver("mariadb").getOrThrow()
    var property1 = ("username", "test_user")
    var property2 = ("password", "test_user")
    var property3 = ("database", "driver_test")
    var dataSource = driver.open("mariadb://localhost", [property1, property2, property3])
    var connection = dataSource.connect()

    var statemnt = connection.prepareStatement("insert into simple values (?, ?, ?, ?, ?, ?, ?, ?)")
    statemnt.set(1, 1000)
    statemnt.set(2, "mariadb")
    statemnt.setNull(3)
    statemnt.set(4, 123.456789)
    statemnt.set(5, Decimal.parse("1.234567"))
    statemnt.set(6, DateTime.now())
    statemnt.set(7, DateTime.now())
    statemnt.set(8, DateTime.now())
    var result = statemnt.update()

    println("effect row: ${result.rowCount} lastInsertId: ${result.lastInsertId}")
  
}
```

#### 获取事务对象

```cangjie
import mariadb.cdbc.*
import std.database.sql.*

main(){
    var driver = DriverManager.getDriver("mariadb").getOrThrow()
    var property1 = ("username" "root")
    var property2 = ("password", "password")
    var property3 = ("database", "test")
    var dataSource = driver.open("mariadb://localhost:3306", [property1,property2,property3])
    var connection =  dataSource.connect()
    var transaction = connection.createTransaction()
    transaction.begin()
    transaction.commit()
}
```

### 3.3 连接参数

| 选项名                  | 功能                                                         | 可选值                                                     | 默认值    | Require                           |
| ----------------------- | ------------------------------------------------------------ | ---------------------------------------------------------- | --------- | --------------------------------- |
| username                | 数据库用户名                                                 |                                                            |           | Yes                               |
| password                | 数据库密码                                                   |                                                            |           | Yes                               |
| host                    | 主机地址                                                     |                                                            |           | Yes                               |
| port                    | 服务端口                                                     |                                                            | 3306      | No                                |
| database                | 数据库                                                       |                                                            |           | No                                |
| connection_timeout      | connect 操作的超时时间，单位 ms。                            |                                                            |           | Nop                               |
| prepare.mode            | 预编译模式                                                   | server或client                                             | server    | No                                |
| ssl.mode                | 传输层加密模式。                                             | disabled,preferred(default),required,verify_ca,verify_full | preferred | No                                |
| ssl.ca                  | 证书颁发机构（ CA ）证书文件的路径名                         |                                                            |           | No                                |
| ssl.cert                | 客户端 SSL 公钥证书文件的路径名。                            |                                                            |           | No                                |
| ssl.key                 | 客户端 SSL 私钥文件的路径名。                                |                                                            |           | 使用了ssl.cert必须指定ssl.key参数 |
| ssl.key.password        | 客户端 SSL 私钥文件的密码。                                  |                                                            |           | No                                |
| ssl.sni                 | 客户端通过该标识在握手过程开始时试图连接到哪个主机名。       |                                                            |           | No                                |
| tls1.2.ciphersuites     | 此选项指定客户端允许使用 TLSv1.2 及以下的加密连接使用哪些密码套件。 |                                                            |           | No                                |
| tls1.3.ciphersuites     | 此选项指定客户端允许使用 TLSv1.3 的加密连接使用哪些密码套件。 |                                                            |           | No                                |
| tls.version             | 支持的 TLS 版本号，值为逗号分隔的字符串，比如 "TLSv1.2,TLSv1.3"。 |                                                            |           | No                                |
| pool.connection.timeout | 从池中获取连接的超时时间。单位 s                             |                                                            | 30        | No                                |
| pool.idle.timeout       | 允许连接在池中闲置的最长时间，超过这个时间的空闲连接可能会被回收。单位 m |                                                            | 10        | No                                |
| pool.keepalive.time     | 检查空闲连接健康状况的间隔时间，防止它被数据库或网络基础设施超时。单位 m |                                                            | 1         | No                                |
| pool.max.idle.size      | 最大空闲连接数量，超过这个数量的空闲连接会被关闭，负数或0表示无限制。 |                                                            | 0         | No                                |
| pool.max.life.time      | 自连接创建以来的持续时间，在该持续时间之后，连接将自动关闭。单位 m |                                                            | 30        | No                                |
| pool.max.size           | 连接池最大连接数量，负数或0表示无限制。                      |                                                            | 10        | No                                |

### 3.4目前已知的一些问题

## <img alt="" src="./doc/readme-image/readme-icon-contribute.png" style="display: inline-block;" width=3%/> 4 参与贡献

本项目由[@Yesokim](https://gitcode.com/Yesokim)实现并维护。技术支持和意见反馈请提Issue。

本项目基于 Apache License 2.0，欢迎给我们提交PR，欢迎参与任何形式的贡献。
