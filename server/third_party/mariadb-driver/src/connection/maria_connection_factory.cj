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

import std.fs.*
import std.net.*
import std.collection.*
import std.convert.*
import stdx.net.tls.*
import stdx.net.tls.common.*
import stdx.crypto.x509.*
import stdx.crypto.keys.*
import mariadb.protocol.*

const SHA256_REQUESET_KEY_CODE: Byte = 0x01
const CACHING_SHA2_REQUEST_KEY_CODE: Byte = 0x02

/**
 * 创建一个完成认证的mariadb连接
 * @params params: Map<String, String> 连接参数
 */
protected func createAuthedConnection(params: Map<String, String>): MariaConnection {
    // 1. 建立TCP连接,设置参数
    let socket = connectToServer(params)
    // 2. 读取握手报文
    let connection = MariaConnection(socket)
    let handshake = connection.readHandhake()
    let sslMode = params.get(Params.SSLMode) ?? "preferred"
    let sslable = handshake.hasCapability(Capability.SSL)
    if (!sslable && sslMode != "disabled" && sslMode != "preferred") {
        throw ConnectFailedException("Can't Switch to SSL after handshake")
    }
    // 3. 建立安全连接
    let sslEnabled = sslable && sslMode != "disabled"
    let authReq = prepareAuthRequest(handshake, params, sslEnabled)
    if (sslEnabled) {
        connection.writeRequest(authReq.setCapability(SSL).sslRequest())
        sslHandshake(connection, sslMode, params)
        authReq.setNumber(authReq.number + 1)
    }
    // 4.发送认证报文
    connection.writeRequest(authReq)
    connection.flush()
    // 5. 处理认证响应,可能是 ErrorResponse, OkResponse, PublicKey ,AuthStatePacket 和 AuthSwitch这几种数据包
    let originPassword = params.get(Params.Password) ?? throw ConnectFailedException("Required connection parameters: password")
    match (connection.readResponse()) {
        case ok: OkResponse => return connection
        case key: PublicKeyResponse => 
            let encryptedPwd = performFullAuthentication(key.publicKey, originPassword.toNullTerminated(), handshake.salt)
            return sendPassword(connection, encryptedPwd, key.number)
        case authSwitch: AuthSwitch =>
            match (authSwitch.pluginName) {
                case "caching_sha2_password" =>
                    let encryptedPwd = cachingSha2Password(originPassword.toArray(), authSwitch.salt)
                    connection.writeRequest(SendPassword(authSwitch.number + 1, encryptedPwd))
                    match (connection.readResponse()) {
                        case authStatus: AuthStatus => 
                            return checkCachingSha2PasswordAuthStatus(connection, authStatus, originPassword, authSwitch.salt, sslEnabled)
                        case response => throw ConnectFailedException("Out expect Response")
                    }
                case "sha256_password" => 
                    if(sslEnabled) {
                        return sendPassword(connection, originPassword.toNullTerminated(), authSwitch.number)
                    } else {
                        let response = requestPublicKey(connection, SHA256_REQUESET_KEY_CODE, authSwitch.number)
                        let encryptedPwd = performFullAuthentication(response.publicKey, originPassword.toNullTerminated(), authSwitch.salt)
                        return sendPassword(connection, encryptedPwd, response.number)
                    }
                case "mysql_native_password" =>
                    let encryptedPwd = mariadbNativePassword(originPassword.toArray(), authSwitch.salt)
                    return sendPassword(connection, encryptedPwd, authSwitch.number);
                case _ => throw ConnectFailedException("Unsupported auth plugin")
            }
        case authStatus: AuthStatus => return checkCachingSha2PasswordAuthStatus(connection, authStatus, originPassword, handshake.salt, sslEnabled)
        case error: ErrorResponse => throw ConnectFailedException(error.message)
        case _ => throw ConnectFailedException("Out expect Response")
    }
}

private func connectToServer(params: Map<String, String>): TcpSocket {
    let host = params.get(Params.Host) ?? "localhost"
    let port = params.get(Params.Port) ?? "3306"
    let socket = TcpSocket(host, UInt16.parse(port))
    let timeout = params.get(Params.ConnectionTimeout)
    match (timeout) {
        case None => socket.connect()
        case Some(v) => 
            // try {
                let timeout = Int64.parse(v)
                socket.connect(timeout: Duration.millisecond * timeout)
            // } catch (e: IllegalArgumentException) {
            //     throw IllegalArgumentException("parse connection timeout failed")
            // }
    }
    return socket
}

private func prepareAuthRequest(handshake: Handshake, params: Map<String, String>, sslEnabled: Bool): HandshakeResponse {
    let username = params.get(Params.Username) ?? throw IllegalArgumentException("Required connection parameters: username")
    let originPassword = params.get(Params.Password) ?? throw IllegalArgumentException("Required connection parameters: password")
    let database = params.get(Params.Database)
    let authReq = HandshakeResponse.getDefault(handshake.number + 1)
    let encryptedPassword: Array<Byte>
    match (handshake.authPlugin) {
        case "caching_sha2_password" => encryptedPassword = cachingSha2Password(originPassword.toArray(),handshake.salt)
        case "sha256_password" => 
            if(sslEnabled) {
                encryptedPassword = originPassword.toNullTerminated()
            } else {
                encryptedPassword = [1]
            }
        case "mysql_native_password" => encryptedPassword = mariadbNativePassword(originPassword.toArray(),handshake.salt)
        case _ => throw ConnectFailedException("Unknow authentication plugin")
    }
    authReq.setUsername(username).setAuthResponse(encryptedPassword).setClientAuthPlugin(handshake.authPlugin)
    if (let Some(v) <- database) {
        authReq.setCapability(ConnectWithDB).setDatabase(v)
    }
    return authReq
}

private func sslHandshake(connection: MariaConnection, sslMode: String, params: Map<String, String>) {
    var config = TlsClientConfig()
    if (sslMode == "preferred" || sslMode == "required" || sslMode == "verify_ca") {
        config.verifyMode = CertificateVerifyMode.TrustAll
    }
    //(config.minVersion, config.maxVersion) = getMinAndMaxTlsVersion(option.get(Params.TlsVersion))
    try {
        let tls: TlsSocket = TlsSocket.client(connection.socket, clientConfig: config)
        tls.handshake()
        connection.socket = tls
    } catch (e: Exception) {
        throw ConnectFailedException(e.message)
    }
}

private func sendPassword(connection: MariaConnection, password: Array<Byte>, lastPacketNumber: UInt8): MariaConnection {
    connection.writeRequest(SendPassword(lastPacketNumber + 1, password))
    let response = connection.readResponse()
    match (response) {
        case ok: OkResponse => return connection
        case error: ErrorResponse => throw ConnectFailedException(error.message)
        case _ => throw ConnectFailedException("Out expect connection response")
    }
}

private func checkCachingSha2PasswordAuthStatus(connection: MariaConnection, authStatus: AuthStatus, originPassword: String, salt: Array<Byte>, sslEnabled: Bool): MariaConnection{
    if (authStatus.state == AuthState.PerformFullAuthentication) {
        if (sslEnabled) {
            return sendPassword(connection, originPassword.toNullTerminated(), authStatus.number)    
        } else {
            let response = requestPublicKey(connection, CACHING_SHA2_REQUEST_KEY_CODE, authStatus.number)
            let encryptedPwd = performFullAuthentication(response.publicKey, originPassword.toNullTerminated(), salt)
            return sendPassword(connection, encryptedPwd, response.number)
        }
    } else if (authStatus.state == AuthState.FastAuthSuccess) {
        let response = connection.readResponse()
        match (response) {
            case r: OkResponse => return connection
            case r: ErrorResponse => throw ConnectFailedException(r.message)
            case _ => throw ConnectFailedException("Out expect Response")
        }
    }
    throw ConnectFailedException("connect to mariadb failed")
}

private func requestPublicKey(connection: MariaConnection, requestKeyCode: Byte, lastPacketNumber: UInt8): PublicKeyResponse {
    let requestkey = RequestPublicKey(lastPacketNumber + 1, requestKeyCode)
    connection.writeRequest(requestkey)
    match (connection.readResponse()) {
        case error: ErrorResponse => throw ConnectFailedException(error.message)
        case publicKey: PublicKeyResponse => return publicKey
        case response => throw ConnectFailedException("Out expect Response")
    }
}

// private static func getMinAndMaxTlsVersion(val: ?String): (TlsVersion, TlsVersion) {
//     if (val.isNone()) {
//         return (V1_2, V1_3)
//     } else {
//         let values = val.getOrThrow().split(",", removeEmpty: true)
//         values.sort()
//         let versions = ArrayList<TlsVersion>()
//         let tls12used = false
//         let tls13used = false
//         for (i in values) {
//             match (i) {
//                 case "TLSv1.2" => if (!tls12used) {
//                     versions.append(V1_2)
//                     tls12used = true
//                 }
//                 case "TLSv1.3" => if (!tls13used) {
//                     versions.append(V1_3)
//                     tls13used = true
//                 }
//                 case _ => throw ConnectFailedException("Unkonw TLS version: ${i}")
//             }
//         }
//         return (versions[0], versions[versions.size - 1])
//     }
// }

private func getClientCertificate(params: Map<String, String>): ?(Array<X509Certificate>, Object) {
    match (params.get(Params.SSLCert)) {
        case None => None
        case Some(publicKeyPath) =>
            match (params.get(Params.SSLKey)) {
                case None => throw ConnectFailedException()
                case Some(privateKeyPath) =>
                    let certificates = X509Certificate.decodeFromPem(String.fromUtf8(File.readFrom(publicKeyPath)))
                    let privateKey: Object = match (certificates[0].publicKeyAlgorithm) {
                        case PublicKeyAlgorithm.RSA => RSAPrivateKey.decodeFromPem(privateKeyPath, password: params.get(Params.SSLKeyPassword))
                        case PublicKeyAlgorithm.ECDSA => ECDSAPrivateKey.decodeFromPem(privateKeyPath, password: params.get(Params.SSLKeyPassword))
                        case _ => throw ConnectFailedException("Unsupported protected key algorithm")
                    }
                    return (certificates, privateKey)
            }
        }
}
