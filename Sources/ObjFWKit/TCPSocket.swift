//
//  OFTCPSocket.swift
//  StreamsKit
//
//  Created by Yury Vovk on 10.05.2018.
//

import Foundation

#if os(Windows)
import CWin32
#endif

open class OFTCPSocket: OFStreamSocket {
    private static var _defaultSOCKS5Host: String?
    private static var _defaultSOCKS5Port: UInt16 = 1080
    
    public class var SOCKS5Host: String? {
        get {
            return _defaultSOCKS5Host
        }
        
        set {
            _defaultSOCKS5Host = newValue
        }
    }
    
    public class var SOCKS5Port: UInt16 {
        get {
            return _defaultSOCKS5Port
        }
        
        set {
            _defaultSOCKS5Port = newValue
        }
    }
    
    public internal(set) var listening: Bool = false
    
    internal var _address: SocketAddress!
    
    public var SOCKS5Host: String? = OFTCPSocket.SOCKS5Host
    public var SOCKS5Port: UInt16 = OFTCPSocket.SOCKS5Port
    
    public required override init() {
        
    }
    
    open func connectToHost(_ host: String, port: UInt16) throws {
        let destinationHost = host
        let destinationPort = port
        
        var _host = host
        var _port = port
        
        guard _socket == nil else {
            throw OFException.alreadyConnected(stream: self)
        }
        
        if self.SOCKS5Host != nil {
            _host = self.SOCKS5Host!
            _port = self.SOCKS5Port
        }
        
        var errNo: Int32 = 0
        
        if let results = try Resolver.resolve(host: _host, port: _port, type: .stream) {
            for addressInfo in results {
                if let address = SocketAddress(addressInfo.address) {
                    _socket = Socket.init(family: addressInfo.family, type: addressInfo.socketType, protocol: addressInfo.protocol)
                    
                    if _socket == nil {
                        continue
                    }
                    
                    if SOCK_CLOEXEC == 0 {
                        #if !os(Windows)
                            var flags: Int32 = 0
                            flags = fcntl(_socket.rawValue, F_GETFD, 0)
                            
                            if flags != -1 {
                                _ = fcntl(_socket.rawValue, F_SETFD, flags | FD_CLOEXEC)
                            }
                        #endif
                    }
                    
                    if !ConnectSocket(_socket, toAddress: address) {
                        errNo = _socket_errno()
                        CloseSocket(_socket)
                        _socket = nil
                        
                        continue
                    }
                    
                    break
                } else {
                    errNo = EHOSTUNREACH
                }
            }
        } else {
            errNo = EHOSTUNREACH
        }
        
        guard _socket != nil else {
            throw OFException.connectionFailed(host: _host, port: _port, socket: self, error: errNo)
        }
        
        if self.SOCKS5Host != nil {
            try self._SOCKS5ConnectToHost(destinationHost, port: destinationPort)
        }
    }
    
    open func asyncConnectToHost(_ host: String, port: UInt16, _ body: @escaping (OFTCPSocket, Error?) -> Void) {
        
        let runloop = RunLoop.current
        
        Thread.asyncExecute {
            var err: Error? = nil
            do {
                try self.connectToHost(host, port: port)
            } catch {
                err = error
            }
            
            runloop.execute {
                body(self, err)
            }
        }
    }
    
    open func bindToHost(_ host: String, port: UInt16 = 0) throws -> UInt16 {
        guard _socket == nil else {
            throw OFException.alreadyConnected(stream: self)
        }
        
        guard let results = try Resolver.resolve(host: host, port: port, type: .stream) else {
            throw OFException.bindFailed(host: host, port: port, socket: self, error: _socket_errno())
        }
        
        if let address = SocketAddress(results[0].address) {
            _socket = Socket(family: results[0].family, type: results[0].socketType, protocol: results[0].protocol)
            
            guard _socket != nil else {
                throw OFException.bindFailed(host: host, port: port, socket: self, error: _socket_errno())
            }
            
            if SOCK_CLOEXEC == 0 {
                #if !os(Windows)
                    var flags: Int32 = 0
                    flags = fcntl(_socket.rawValue, F_GETFD, 0)
                    
                    if flags != -1 {
                        _ = fcntl(_socket.rawValue, F_SETFD, flags | FD_CLOEXEC)
                    }
                #endif
            }
            
            var one:Int32 = 1
            _ = withUnsafePointer(to: &one) {
                setsockopt(_socket.rawValue, SOL_SOCKET, SO_REUSEADDR, $0, socklen_t(MemoryLayout<Int32>.size))
            }
            
            guard BindSocket(_socket, onAddress: address) else {
                let error = _socket_errno()
                CloseSocket(_socket)
                _socket = nil
                
                throw OFException.bindFailed(host: host, port: port, socket: self, error: error)
            }
            
            if port > 0 {
                return port
            }
            
            let boundAddress = try SocketAddress {
                guard Resolver.getSockName(_socket, $0, $1) else {
                    let error = _socket_errno()
                    CloseSocket(_socket)
                    _socket = nil
                    
                    throw OFException.bindFailed(host: host, port: port, socket: self, error: error)
                }
            }
            
            switch boundAddress {
            case .ipv4(var _address):
                return withUnsafeMutablePointer(to: &_address) {
                    return $0.pointee.sin_port
                }
            case .ipv6(var _address):
                return withUnsafeMutablePointer(to: &_address) {
                    return $0.pointee.sin6_port
                }
            default:
                break
            }
            
            CloseSocket(_socket)
            _socket = nil
            
            throw OFException.bindFailed(host: host, port: port, socket: self, error: EAFNOSUPPORT)
            
        } else {
            throw OFException.bindFailed(host: host, port: port, socket: self, error: EHOSTUNREACH)
        }
    }
    
    open func listen(withBackLog backlog: Int = Int(SOMAXCONN)) throws {
        guard _socket != nil else {
            throw OFException.notOpen(stream: self)
        }
        
        guard ListenOnSocket(_socket, withBacklog: backlog) else {
            throw OFException.listenFailed(socket: self, backlog: backlog, error: _socket_errno())
        }
        
        self.listening = true
    }
    
    open func accept() throws -> OFTCPSocket {
        
        let (socket, address) = AcceptSocket(self._socket)
        
        guard socket != nil else {
            throw OFException.acceptFailed(socket: self, error: _socket_errno())
        }
        
        let client = type(of: self).init()
        
        client._socket = socket
        client._address = address
        
        #if !os(Windows)
        let flags = fcntl(client._socket.rawValue, F_GETFD, 0)
        if flags != -1 {
            _ = fcntl(client._socket.rawValue, F_SETFD, flags | FD_CLOEXEC)
        }
        #endif
        
        assert(client._address.size <= socklen_t(MemoryLayout<sockaddr_storage>.size))
        
        return client
    }
    
    open func asyncAccept(_ body: @escaping (OFTCPSocket, OFTCPSocket?, Error?) -> Bool) {
        StreamObserver.current._addAsyncAcceptForTCPSocket(self, block: body)
    }
    
    open func isKeepAliveEnabled() throws -> Bool {
        var enabled = Int32()
        let len = UnsafeMutablePointer<socklen_t>.allocate(capacity: 1)
        len.pointee = socklen_t(MemoryLayout<Int32>.size)
        
        defer {
            len.deallocate(capacity: 1)
        }
        
        let rc = withUnsafeMutablePointer(to: &enabled) {
            return getsockopt(_socket.rawValue, SOL_SOCKET, SO_KEEPALIVE, $0, len)
        }
        
        guard rc == 0 && rc == len.pointee else {
            throw OFException.getOptionFailed(stream: self, error: _socket_errno())
        }
        
        return enabled != 0
    }
    
    open func setKeepAliveEnabled(_ enabled: Bool) throws {
        var _enabled: Int32 = enabled ? 1 : 0
        
        let rc = withUnsafeMutablePointer(to: &_enabled) {
            return setsockopt(_socket.rawValue, SOL_SOCKET, SO_KEEPALIVE, $0, socklen_t(MemoryLayout<Int32>.size))
        }
        
        guard rc == 0 else {
            throw OFException.setOptionFailed(stream: self, error: _socket_errno())
        }
    }
    
    open func isTCPNoDelayEnabled() throws -> Bool {
        var enabled = Int32()
        var len = UnsafeMutablePointer<socklen_t>.allocate(capacity: 1)
        len.pointee = socklen_t(MemoryLayout<Int32>.size)
        
        defer {
            len.deallocate(capacity: 1)
        }
        
        let rc = withUnsafeMutablePointer(to: &enabled) {
            return getsockopt(_socket.rawValue, IPPROTO_TCP, TCP_NODELAY, $0, len)
        }
        
        guard rc == 0 && rc == len.pointee else {
            throw OFException.getOptionFailed(stream: self, error: _socket_errno())
        }
        
        return enabled != 0
    }
    
    open func setTCPNoDelayEnabled(_ enabled: Bool) throws {
        var _enabled: Int32 = enabled ? 1 : 0
        
        let rc = withUnsafeMutablePointer(to: &_enabled) {
            return setsockopt(_socket.rawValue, IPPROTO_TCP, TCP_NODELAY, $0, socklen_t(MemoryLayout<Int32>.size))
        }
        
        guard rc == 0 else {
            throw OFException.setOptionFailed(stream: self, error: _socket_errno())
        }
    }
    
    open override func close() throws {
        self.listening = false
        
        try super.close()
    }
}

@inline(__always)
fileprivate func sendOrThrow(_ self: OFTCPSocket, _ socket: Socket, _ buffer: UnsafeMutablePointer<CChar>!, _ len: Int32) throws {
    var bytesWritten: Int
    
    #if os(Windows)
    let _bytesWritten = send(socket.rawValue, buffer, UInt32(len), 0)
    bytesWriten = Int(_bytesWritten)
    #else
    bytesWritten = send(socket.rawValue, buffer, Int(len), 0)
    #endif
    
    guard bytesWritten >= 0 else {
        throw OFException.writeFailed(stream: self, requestedLength: Int(len), bytesWritten: 0, error: _socket_errno())
    }
    
    guard bytesWritten == Int(len) else {
        throw OFException.writeFailed(stream: self, requestedLength: Int(len), bytesWritten: bytesWritten, error: _socket_errno())
    }
}

@inline(__always)
fileprivate func recvExact(_ self: OFTCPSocket, _ socket: Socket, _ buffer: UnsafeMutablePointer<CChar>!, _ len: Int32) throws {
    var length = Int(len)
    var _buffer = buffer
    
    while length > 0 {
        #if os(Windows)
        let ret = recv(socket.rawValue, _buffer, UInt32(length), 0)
        #else
        let ret = recv(socket.rawValue, _buffer, length, 0)
        #endif
        
        guard ret >= 0 else {
            throw OFException.readFailed(stream: self, requestedLength: length, error: _socket_errno())
        }
        
        _buffer = _buffer!.advanced(by: ret)
        length -= ret
    }
}

fileprivate extension OFTCPSocket {
    func _SOCKS5ConnectToHost(_ host: String, port: UInt16) throws {
        guard host.lengthOfBytes(using: .utf8) <= 256 else {
            throw OFException.outOfRange()
        }
        
        var request = UnsafeMutablePointer<CChar>.allocate(capacity: 4)
        
        defer {
            request.deallocate(capacity: 4)
        }
        
        request[0] = 5
        request[1] = 1
        request[2] = 0
        request[3] = 3
        
        let reply = UnsafeMutablePointer<CChar>.allocate(capacity: 256)
        
        try sendOrThrow(self, _socket, request, 3)
        try recvExact(self, _socket, reply, 2)
        
        guard reply[0] == 5 && reply[1] == 0 else {
            try self.close()
            
            throw OFException.connectionFailed(host: host, port: port, socket: self, error: EPROTONOSUPPORT)
        }
        
        do {
            var connectionRequest = Data(bytes: request, count: 4)
            
            let utf8StringLength = host.lengthOfBytes(using: .utf8)
            request[0] = CChar()
            request.withMemoryRebound(to: UInt8.self, capacity: 4) {
                connectionRequest.append($0, count: 4)
            }
            host.withCString {cstr in
                cstr.withMemoryRebound(to: UInt8.self, capacity: utf8StringLength) {bytes in
                    connectionRequest.append(bytes, count: utf8StringLength)
                }
            }
            
            request[0] = CChar(port >> 8)
            request[1] = CChar(port & 0xFF)
            
            request.withMemoryRebound(to: UInt8.self, capacity: 4) {
                connectionRequest.append($0, count: 2)
            }
            
            guard connectionRequest.count <= INT_MAX else {
                throw OFException.outOfRange()
            }
            
            try connectionRequest.withUnsafeMutableBytes {bytes in
                try sendOrThrow(self, _socket, bytes, Int32(connectionRequest.count))
            }
        }
        
        try recvExact(self, _socket, reply, 4)
        
        guard reply[0] == 5 && reply[2] == 0 else {
            try self.close()
            
            throw OFException.connectionFailed(host: host, port: port, socket: self, error: EPROTONOSUPPORT)
        }
        
        if reply[1] != 0 {
            try self.close()
            var error: Int32
            
            switch reply[1] {
            case 0x02:
                error = EACCES
            case 0x03:
                error = ENETUNREACH
            case 0x04:
                error = EHOSTUNREACH
            case 0x05:
                error = ECONNREFUSED
            case 0x06:
                error = ETIMEDOUT
            case 0x07:
                error = EPROTONOSUPPORT
            case 0x08:
                error = EAFNOSUPPORT
            default:
                error = 0
            }
            
            throw OFException.connectionFailed(host: host, port: port, socket: self, error: error)
        }
        
        switch reply[3] {
        case 1:
            try recvExact(self, _socket, reply, 4)
        case 3:
            do {
                try recvExact(self, _socket, reply, 1)
                try recvExact(self, _socket, reply, Int32(reply[0]))
            }
        case 4:
            try recvExact(self, _socket, reply, 16)
        default:
            do {
                try self.close()
                
                throw OFException.connectionFailed(host: host, port: port, socket: self, error: EPROTONOSUPPORT)
            }
        }
        
        try recvExact(self, _socket, reply, 2)
    }
}
