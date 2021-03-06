//
//  Stream.swift
//  StreamsKit
//
//  Created by Yury Vovk on 08.05.2018.
//

import Foundation

public protocol OFReadyForReadingObserving: class {
    var sourceForReading: CFRunLoopSource {get}
}

public protocol OFReadyForWritingObserving: class {
    var sourceForWriting: CFRunLoopSource {get}
}

open class OFStream {
    public enum ByteOrder {
        case bigEndian
        case littleEndian
        
        public static let current: OFStream.ByteOrder = {
            let number: UInt32 = 0x12345678
            
            if number == number.bigEndian {
                return .bigEndian
            } else {
                return .littleEndian
            }
        }()
    }
    
    internal static let MIN_READ_SIZE = 512
    
    
    internal var _readBufferLength: Int = 0
    internal var _readBufferMemmory: UnsafeMutableRawBufferPointer!
    internal var _readBuffer: UnsafeMutableRawPointer!
    
    internal var _writeBufferLength: Int = 0
    internal var _writeBuffer: UnsafeMutableRawBufferPointer!
    
    internal var _waitingForDelimiter: Bool = false
    
    internal func _resizeIntenalBuffer(_ buffer: UnsafeMutableRawBufferPointer?, size: Int) -> UnsafeMutableRawBufferPointer {
        
        if buffer == nil {
            return UnsafeMutableRawBufferPointer.allocate(count: size)
        }
        
        defer {
            buffer!.deallocate()
        }
        
        let newBuffer = UnsafeMutableRawBufferPointer.allocate(count: buffer!.count + size)
        newBuffer.baseAddress!.copyBytes(from: buffer!.baseAddress!, count: buffer!.count)
        
        return newBuffer
    }
    
    open var writeBuffered: Bool = false
    internal var _blocking: Bool = true
    
    open var isBlocking: Bool {
        get {
            return _blocking
        }
    }
    
    
    open lazy var outputStream: OutputStream = OFOutputStream(ofStream: self)
    
    open lazy var inputStream: InputStream = OFInputStream(ofStream: self)
    
    open func setBlocking(_ enable: Bool) throws {
        throw OFException.notImplemented(method: #function, inStream: type(of: self))
    }
    
    open func lowLevelRead(into buffer: inout UnsafeMutableRawPointer, length: Int) throws -> Int {
        throw OFException.notImplemented(method: #function, inStream: type(of: self))
    }
    
    @discardableResult
    open func lowLevelWrite(_ buffer: UnsafeRawPointer, length: Int) throws -> Int {
        throw OFException.notImplemented(method: #function, inStream: type(of: self))
    }
    
    open func lowLevelIsAtEndOfStream() throws -> Bool {
        throw OFException.notImplemented(method: #function, inStream: type(of: self))
    }
    
    open func atEndOfStream() throws -> Bool {
        if _readBufferLength > 0 {
            return false
        }
        
        return try self.lowLevelIsAtEndOfStream()
    }
    
    open var hasDataInReadBuffer: Bool {
        return _readBufferLength > 0
    }
    
    open func readIntoBuffer(_ buffer: inout UnsafeMutableRawPointer, length: Int) throws -> Int {
        if _readBufferLength == 0 {
            if length < OFStream.MIN_READ_SIZE {
                var tmp = UnsafeMutableRawPointer.allocate(bytes: OFStream.MIN_READ_SIZE, alignedTo: MemoryLayout<UInt8>.size)
                tmp.initializeMemory(as: UInt8.self, to: 0)
                
                defer {
                    tmp.deallocate(bytes: OFStream.MIN_READ_SIZE, alignedTo: MemoryLayout<UInt8>.size)
                }
                
                let bytesRead = try self.lowLevelRead(into: &tmp, length: OFStream.MIN_READ_SIZE)
                
                if bytesRead > length {
                    buffer.copyBytes(from: tmp, count: length)
                    
                    let readBuffer = UnsafeMutableRawBufferPointer.allocate(count: bytesRead - length)
                    readBuffer.baseAddress!.copyBytes(from: tmp + length, count: bytesRead - length)
                    
                    _readBufferMemmory = readBuffer
                    _readBuffer = _readBufferMemmory.baseAddress
                    _readBufferLength = bytesRead - length
                    
                } else {
                    buffer.copyBytes(from: tmp, count: bytesRead)
                    
                    return bytesRead
                }
            }
            
            return try self.lowLevelRead(into: &buffer, length: length)
        }
        
        if length >= _readBufferLength {
            let ret = _readBufferLength
            
            buffer.copyBytes(from: _readBuffer, count: _readBufferLength)
            _readBuffer = nil
            _readBufferLength = 0
            _readBufferMemmory.deallocate()
            _readBufferMemmory = nil
            
            return ret
        } else {
            buffer.copyBytes(from: _readBuffer, count: length)
            _readBuffer = _readBuffer.advanced(by: length)
            _readBufferLength -= length
            
            return length
        }
    }
    
    open func asyncRead(into buffer: inout UnsafeMutableRawPointer, length: Int, _ body: @escaping OFAsyncReadBufferBlock) {
        
        StreamObserver.current._addAsyncReadForStream(self, buffer: buffer, length: length, block: body)
    }
    
    open func readIntoBuffer(_ buffer: inout UnsafeMutableRawPointer, exactLength length: Int) throws {
        var readLength = Int(0)
        
        while readLength < length {
            if try self.atEndOfStream() {
                throw OFException.truncatedData()
            }
            
            var tmp = buffer + readLength
            readLength += try self.readIntoBuffer( &tmp, length: length - readLength)
        }
    }
    
    open func asyncRead(into buffer: inout UnsafeMutableRawPointer, exactLength length: Int, _ body: @escaping OFAsyncReadBufferBlock) {
        
        StreamObserver.current._addAsyncReadForStream(self, buffer: buffer, exactLength: length, block: body)
    }
    
    @discardableResult
    open func writeBuffer(_ buffer: UnsafeRawPointer, length: Int) throws -> Int {
        if !writeBuffered {
            let bytesWritten = try self.lowLevelWrite(buffer, length: length)
            
            if _blocking && bytesWritten < length {
                throw OFException.writeFailed(stream: self, requestedLength: length, bytesWritten: bytesWritten, error: 0)
            }
            
            return bytesWritten
            
        } else {
            _writeBuffer = self._resizeIntenalBuffer(_writeBuffer, size: _writeBufferLength + length)
            _writeBuffer.baseAddress!.advanced(by: _writeBufferLength).copyBytes(from: buffer, count: length)
            _writeBufferLength += length
            
            return length
        }
    }
    
    open func asyncWrite(buffer: UnsafeRawPointer, length: Int, _ body: @escaping OFAsyncWriteBufferBlock) {
        
        StreamObserver.current._addAsyncWriteForStream(self, buffer: buffer, length: length, block: body)
    }
    
    @inline(__always)
    internal func _readInteger<T>() throws -> T where T: FixedWidthInteger {
        var buffer = UnsafeMutableRawPointer.allocate(bytes: MemoryLayout<T>.size, alignedTo: MemoryLayout<T>.alignment)
        
        defer {
            buffer.deallocate(bytes: MemoryLayout<T>.size, alignedTo: MemoryLayout<T>.alignment)
        }
        
        try self.readIntoBuffer( &buffer, exactLength: MemoryLayout<T>.size)
        
        return buffer.assumingMemoryBound(to: T.self).pointee
    }
    
    open func readInt8() throws -> UInt8 {
        return try self._readInteger()
    }
    
    open func readInt16(byteOrder: OFStream.ByteOrder = .current) throws -> UInt16 {
        let result: UInt16 = try self._readInteger()
        
        switch byteOrder {
        case .bigEndian:
            return CFSwapInt16BigToHost(result)
        case .littleEndian:
            return CFSwapInt16LittleToHost(result)
        }
    }
    
    open func readInt32(byteOrder: OFStream.ByteOrder = .current) throws -> UInt32 {
        let result: UInt32 = try self._readInteger()
        
        switch byteOrder {
        case .bigEndian:
            return CFSwapInt32BigToHost(result)
        case .littleEndian:
            return CFSwapInt32LittleToHost(result)
        }
    }
    
    open func readInt64(byteOrder: OFStream.ByteOrder = .current) throws -> UInt64 {
        let result: UInt64 = try self._readInteger()
        
        switch byteOrder {
        case .bigEndian:
            return CFSwapInt64BigToHost(result)
        case .littleEndian:
            return CFSwapInt64LittleToHost(result)
        }
    }
    
    open func readFloat(byteOrder: OFStream.ByteOrder = .current) throws -> Float {
        let value = try self.readInt32()
        
        if byteOrder != ByteOrder.current {
            return CFConvertFloatSwappedToHost(CFSwappedFloat32(v: value))
        }
        
        return Float(bitPattern: value)
    }
    
    open func readDouble(byteOrder: OFStream.ByteOrder = .current) throws -> Double {
        let value = try self.readInt64()
        
        if byteOrder != ByteOrder.current {
            return CFConvertDoubleSwappedToHost(CFSwappedFloat64(v: value))
        }
        
        return Double(bitPattern: value)
    }
    
    @inline(__always)
    internal func _writeInteger<T>(_ v: T) throws where T: FixedWidthInteger {
        var _v = v
        
        _ = try withUnsafePointer(to: &_v) {
            try self.writeBuffer( $0, length: MemoryLayout<T>.size)
        }
    }
    
    open func writeInt8(_ v: UInt8) throws {
        var _v = v
        _ = try withUnsafePointer(to: &_v) {
            try self.writeBuffer( $0, length: MemoryLayout<UInt8>.size)
        }
    }
    
    open func writeInt16(_ v: UInt16, byteOrder: OFStream.ByteOrder = .current) throws {
        let _v: UInt16
        
        switch byteOrder {
        case .bigEndian:
            _v = CFSwapInt16HostToBig(v)
        case .littleEndian:
            _v = CFSwapInt16HostToLittle(v)
        }
        
        try self._writeInteger(_v)
    }
    
    open func writeInt32(_ v: UInt32, byteOrder: OFStream.ByteOrder = .current) throws {
        let _v: UInt32
        
        switch byteOrder {
        case .bigEndian:
            _v = CFSwapInt32HostToBig(v)
        case .littleEndian:
            _v = CFSwapInt32HostToLittle(v)
        }
        
        try self._writeInteger(_v)
    }
    
    open func writeInt64(_ v: UInt64, byteOrder: OFStream.ByteOrder = .current) throws {
        let _v: UInt64
        
        switch byteOrder {
        case .bigEndian:
            _v = CFSwapInt64HostToBig(v)
        case .littleEndian:
            _v = CFSwapInt64HostToLittle(v)
        }
        
        try self._writeInteger(_v)
    }
    
    open func writeFloat(_ v: Float, byteOrder: OFStream.ByteOrder = .current) throws {
        let _v: UInt32
        
        if byteOrder != ByteOrder.current {
            _v = CFConvertFloatHostToSwapped(v).v
        } else {
            _v = UInt32(v)
        }
        
        try self._writeInteger(_v)
    }
    
    open func writeDouble(_ v: Double, byteOrder: OFStream.ByteOrder = .current) throws {
        let _v: UInt64
        
        if byteOrder != ByteOrder.current {
            _v = CFConvertDoubleHostToSwapped(v).v
        } else {
            _v = UInt64(v)
        }
        
        try self._writeInteger(_v)
    }
    
    @inline(__always)
    internal func _readIntegers<T>(count: Int) throws -> (UnsafeMutablePointer<T>, Int) where T: FixedWidthInteger {
        guard count <= Int.max / MemoryLayout<T>.size else {
            throw OFException.outOfRange()
        }
        
        let size = count * MemoryLayout<T>.size
        
        var buffer = UnsafeMutableRawPointer.allocate(bytes: size, alignedTo: MemoryLayout<T>.alignment)
        
        do {
            try self.readIntoBuffer( &buffer, exactLength: size)
        } catch {
            buffer.deallocate(bytes: size, alignedTo: MemoryLayout<T>.alignment)
            
            throw error
        }
        
        return (buffer.assumingMemoryBound(to: T.self), size)
    }
    
    open func readInt16s(into buffer: inout UnsafeMutablePointer<UInt16>, count: Int, byteOrder: OFStream.ByteOrder = .current) throws -> Int {
        let (integers, size) = try self._readIntegers(count: count) as (UnsafeMutablePointer<UInt16>, Int)
        
        defer {
            integers.deallocate(capacity: count)
        }
        
        for i in 0..<count {
            switch byteOrder {
            case .bigEndian:
                buffer[i] = CFSwapInt16BigToHost(integers[i])
            case .littleEndian:
                buffer[i] = CFSwapInt16LittleToHost(integers[i])
            }
        }
        
        return size
    }
    
    open func readInt32s(into buffer: inout UnsafeMutablePointer<UInt32>, count: Int, byteOrder: OFStream.ByteOrder = .current) throws -> Int {
        let (integers, size) = try self._readIntegers(count: count) as (UnsafeMutablePointer<UInt32>, Int)
        
        defer {
            integers.deallocate(capacity: count)
        }
        
        for i in 0..<count {
            switch byteOrder {
            case .bigEndian:
                buffer[i] = CFSwapInt32BigToHost(integers[i])
            case .littleEndian:
                buffer[i] = CFSwapInt32LittleToHost(integers[i])
            }
        }
        
        return size
    }
    
    open func readInt64s(into buffer: inout UnsafeMutablePointer<UInt64>, count: Int, byteOrder: OFStream.ByteOrder = .current) throws -> Int {
        let (integers, size) = try self._readIntegers(count: count) as (UnsafeMutablePointer<UInt64>, Int)
        
        defer {
            integers.deallocate(capacity: count)
        }
        
        for i in 0..<count {
            switch byteOrder {
            case .bigEndian:
                buffer[i] = CFSwapInt64BigToHost(integers[i])
            case .littleEndian:
                buffer[i] = CFSwapInt64LittleToHost(integers[i])
            }
        }
        
        return size
    }
    
    open func readFloats(into buffer: inout UnsafeMutablePointer<Float>, count: Int, byteOrder: OFStream.ByteOrder = .current) throws -> Int {
        let (integers, size) = try self._readIntegers(count: count) as (UnsafeMutablePointer<UInt32>, Int)
        
        defer {
            integers.deallocate(capacity: count)
        }
        
        let shouldSwap = ByteOrder.current != byteOrder
        
        for i in 0..<count {
            if shouldSwap {
                buffer[i] = CFConvertFloatSwappedToHost(CFSwappedFloat32(v: integers[i]))
            } else {
                buffer[i] = Float(bitPattern: integers[i])
            }
        }
        
        return size
    }
    
    open func readDoubles(into buffer: inout UnsafeMutablePointer<Double>, count: Int, byteOrder: OFStream.ByteOrder = .current) throws -> Int {
        let (integers, size) = try self._readIntegers(count: count) as (UnsafeMutablePointer<UInt64>, Int)
        
        defer {
            integers.deallocate(capacity: count)
        }
        
        let shouldSwap = ByteOrder.current != byteOrder
        
        for i in 0..<count {
            if shouldSwap {
                buffer[i] = CFConvertDoubleSwappedToHost(CFSwappedFloat64(v: integers[i]))
            } else {
                buffer[i] = Double(bitPattern: integers[i])
            }
        }
        
        return size
    }
    
    @inline(__always)
    internal func _writeIntegers<T>(_ v: UnsafePointer<T>, _ count: Int) throws -> Int where T: FixedWidthInteger {
        let size = count * MemoryLayout<T>.size
        
        try self.writeBuffer( v, length: size)
        
        return size
    }
    
    @inline(__always)
    internal func _writeIntegers<T>(_ v: UnsafePointer<T>, _ count: Int, _ swapper: (T) -> T) throws -> Int where T: FixedWidthInteger {
        guard count <= Int.max / MemoryLayout<T>.size else {
            throw OFException.outOfRange()
        }
        
        var buffer = UnsafeMutablePointer<T>.allocate(capacity: count)
        
        defer {
            buffer.deallocate(capacity: count)
        }
        
        for i in 0..<count {
            buffer[i] = swapper(v[i])
        }
        
        return try self._writeIntegers(buffer, count)
    }
    
    open func writeInt16s(_ v: UnsafePointer<UInt16>, count: Int, byteOrder: OFStream.ByteOrder = .current) throws -> Int {
        return try self._writeIntegers(v, count) {
            switch byteOrder {
            case .bigEndian:
                return CFSwapInt16HostToBig($0)
            case .littleEndian:
                return CFSwapInt16HostToLittle($0)
            }
        }
    }
    
    open func writeInt32s(_ v: UnsafePointer<UInt32>, count: Int, byteOrder: OFStream.ByteOrder = .current) throws -> Int {
        return try self._writeIntegers(v, count) {
            switch byteOrder {
            case .bigEndian:
                return CFSwapInt32HostToBig($0)
            case .littleEndian:
                return CFSwapInt32HostToLittle($0)
            }
        }
    }
    
    open func writeInt64s(_ v: UnsafePointer<UInt64>, count: Int, byteOrder: OFStream.ByteOrder = .current) throws -> Int {
        return try self._writeIntegers(v, count) {
            switch byteOrder {
            case .bigEndian:
                return CFSwapInt64HostToBig($0)
            case .littleEndian:
                return CFSwapInt64HostToLittle($0)
            }
        }
    }
    
    open func writeFloats(_ v: UnsafePointer<Float>, count: Int, byteOrder: OFStream.ByteOrder = .current) throws -> Int {
        guard count <= Int.max / MemoryLayout<UInt32>.size else {
            throw OFException.outOfRange()
        }
        
        var buffer = UnsafeMutablePointer<UInt32>.allocate(capacity: count)
        
        defer {
            buffer.deallocate(capacity: count)
        }
        
        let shouldSwap = ByteOrder.current != byteOrder
        
        for i in 0..<count {
            if shouldSwap {
                buffer[i] = CFConvertFloatHostToSwapped(v[i]).v
            } else {
                buffer[i] = UInt32(v[i])
            }
        }
        
        return try self._writeIntegers(buffer, count)
    }
    
    open func writeDoubles(_ v: UnsafePointer<Double>, count: Int, byteOrder: OFStream.ByteOrder = .current) throws -> Int {
        guard count <= Int.max / MemoryLayout<UInt64>.size else {
            throw OFException.outOfRange()
        }
        
        var buffer = UnsafeMutablePointer<UInt64>.allocate(capacity: count)
        
        defer {
            buffer.deallocate(capacity: count)
        }
        
        let shouldSwap = ByteOrder.current != byteOrder
        
        for i in 0..<count {
            if shouldSwap {
                buffer[i] = CFConvertDoubleHostToSwapped(v[i]).v
            } else {
                buffer[i] = UInt64(v[i])
            }
        }
        
        return try self._writeIntegers(buffer, count)
    }
    
    open func readData(bytesCount count: Int) throws -> Data {
        var buffer = UnsafeMutableRawPointer.allocate(bytes: count, alignedTo: MemoryLayout<UInt8>.alignment)
        
        do {
            try self.readIntoBuffer( &buffer, exactLength: count)
        } catch {
            buffer.deallocate(bytes: count, alignedTo: MemoryLayout<UInt8>.alignment)
            
            throw error
        }
        
        return Data(bytesNoCopy: buffer, count: count, deallocator: .custom({$0.deallocate(bytes: $1, alignedTo: MemoryLayout<UInt8>.alignment)}))
    }
    
    open func readDataUntilEndOfStream() throws -> Data {
        var data = Data()
        let pageSyze = NSPageSize()
        
        var buffer = UnsafeMutableRawPointer.allocate(bytes: pageSyze, alignedTo: MemoryLayout<UInt8>.alignment)
        
        defer {
            buffer.deallocate(bytes: pageSyze, alignedTo: MemoryLayout<UInt8>.alignment)
        }
        
        while try !self.atEndOfStream() {
            let length = try self.readIntoBuffer( &buffer, length: pageSyze)
            
            data.append(buffer.assumingMemoryBound(to: UInt8.self), count: length)
        }
        
        return data
    }
    
    open func tryReadData(tillDelimiter delimiter: Data) throws -> Data? {
        
        return try delimiter.withUnsafeBytes { (delimiterPtr: UnsafePointer<UInt8>) -> Data? in
            var ret: Data? = nil
            var j = Int(0)
            
            if !_waitingForDelimiter && _readBuffer != nil {
                let readBuffer = _readBuffer.assumingMemoryBound(to: UInt8.self)
                
                for i in 0..<_readBufferLength {
                    let delimiterIndex = j
                    j += 1
                    
                    if readBuffer[i] != delimiterPtr[delimiterIndex] {
                        j = 0
                    }
                    
                    if j == delimiter.count {
                        ret = Data(bytes: _readBuffer, count: i + 1 - delimiter.count)
                        
                        _readBuffer = _readBuffer.advanced(by: i + 1)
                        _readBufferLength -= i + 1
                        _waitingForDelimiter = false
                        
                        return ret
                    }
                }
            }
            
            if try self.lowLevelIsAtEndOfStream() {
                guard _readBuffer != nil else {
                    _waitingForDelimiter = false
                    
                    return nil
                }
                
                if _readBufferLength > 0 {
                    ret = Data(bytes: _readBuffer, count: _readBufferLength)
                }
                
                _readBufferMemmory.deallocate()
                _readBuffer = nil
                _readBufferLength = 0
                _waitingForDelimiter = false
                
                return ret
            }
            
            let pageSize = NSPageSize()
            var buffer = UnsafeMutableRawPointer.allocate(bytes: pageSize, alignedTo: MemoryLayout<UInt8>.alignment)
            
            defer {
                buffer.deallocate(bytes: pageSize, alignedTo: MemoryLayout<UInt8>.alignment)
            }
            
            let bufferLength = try self.lowLevelRead(into: &buffer, length: pageSize)
            
            let readBuffer = buffer.assumingMemoryBound(to: UInt8.self)
            
            for i in 0..<bufferLength {
                let delimiterIndex = j
                j += 1
                
                if readBuffer[i] != delimiterPtr[delimiterIndex] {
                    j = 0
                }
                
                if j == delimiter.count {
                    let retLength = _readBufferLength + i + 1 - delimiter.count
                    
                    ret = Data()
                    
                    if _readBuffer != nil && _readBufferLength <= retLength {
                        ret?.append(_readBuffer.assumingMemoryBound(to: UInt8.self), count: _readBufferLength)
                    } else if _readBuffer != nil {
                        ret?.append(_readBuffer.assumingMemoryBound(to: UInt8.self), count: retLength)
                    }
                    
                    if i >= delimiter.count {
                        ret?.append(readBuffer, count: i + 1 - delimiter.count)
                    }
                    
                    if _readBuffer != nil {
                        _readBufferMemmory.deallocate()
                        _readBuffer = nil
                        _readBufferLength = 0
                    }
                    
                    _readBufferMemmory = UnsafeMutableRawBufferPointer.allocate(count: bufferLength - i - 1)
                    _readBuffer = _readBufferMemmory.baseAddress
                    
                    _readBuffer.copyBytes(from: buffer.advanced(by: i + 1), count: bufferLength - i - 1)
                    _readBufferLength = bufferLength - i - 1
                    
                    _waitingForDelimiter = false
                    
                    return ret
                }
            }
            
            if bufferLength > 0 {
                _readBuffer = nil
                _readBufferMemmory = self._resizeIntenalBuffer(_readBufferMemmory, size: bufferLength)
                _readBuffer = _readBufferMemmory.baseAddress
                
                _readBuffer.advanced(by: _readBufferLength).copyBytes(from: buffer, count: bufferLength)
                _readBufferLength += bufferLength
                
            }
            
            _waitingForDelimiter = true
            
            return nil
        }
    }
    
    open func readData(tillDelimiter delimiter: Data) throws -> Data? {
        var data: Data? = nil
        
        while (data = try self.tryReadData(tillDelimiter: delimiter), data).1 == nil {
            guard try !self.atEndOfStream() else {
                return nil
            }
        }
        
        return data
    }
    
    @discardableResult
    open func writeData(_ data: Data) throws -> Int {
        _ = try data.withUnsafeBytes {(buffer: UnsafePointer<UInt8>) in
            try self.writeBuffer( buffer, length: data.count)
        }
        
        return data.count
    }
    
    open func readString(withLength length: Int, encoding: String.Encoding = .utf8) throws -> String? {
        let data = try self.readData(bytesCount: length)
        
        return String(data: data, encoding: encoding)
    }
    
    open func tryReadLine(withEncoding encoding: String.Encoding = .utf8) throws -> String? {
        var retLength: Int
        var ret: String? = nil
        
        if !_waitingForDelimiter && _readBuffer != nil {
            let readBuffer = _readBuffer!.assumingMemoryBound(to: CChar.self)
            for i in 0..<_readBufferLength {
                if readBuffer[i] == 0xA || readBuffer[i] == 0x0 {
                    retLength = i
                    
                    if i > 0 && readBuffer[i - 1] == 0xD {
                        retLength -= 1
                    }
                    
                    ret = String(data: Data(bytesNoCopy: _readBuffer, count: retLength, deallocator: .none), encoding: encoding)
                    
                    guard ret != nil else {
                        throw OFException.invalidEncoding(encoding)
                    }
                    
                    _readBuffer = _readBuffer.advanced(by: i + 1)
                    _readBufferLength -= i + 1
                    _waitingForDelimiter = false
                    
                    return ret
                }
            }
        }
        
        if try self.lowLevelIsAtEndOfStream() {
            guard _readBuffer != nil else {
                _waitingForDelimiter = false
                return nil
            }
            
            let readBuffer = _readBuffer.assumingMemoryBound(to: CChar.self)
            retLength = _readBufferLength
            
            if retLength > 0 && readBuffer[retLength - 1] == 0xD {
                retLength -= 1
            }
            
            ret = String(data: Data(bytesNoCopy: _readBuffer, count: retLength, deallocator: .none), encoding: encoding)
            
            guard ret != nil else {
                throw OFException.invalidEncoding(encoding)
            }
            
            _readBuffer = nil
            _readBufferLength = 0
            _readBufferMemmory.deallocate()
            _waitingForDelimiter = false
            
            return ret
        }
        
        let pageSize = NSPageSize()
        var buffer = UnsafeMutableRawPointer.allocate(bytes: pageSize, alignedTo: MemoryLayout<UInt8>.alignment)
        
        defer {
            buffer.deallocate(bytes: pageSize, alignedTo: MemoryLayout<UInt8>.alignment)
        }
        
        let bufferLength = try self.lowLevelRead(into: &buffer, length: pageSize)
        
        let readBuffer = buffer.assumingMemoryBound(to: CChar.self)
        
        for i in 0..<bufferLength {
            if readBuffer[i] == 0xA || readBuffer[i] == 0x0 {
                do {
                    retLength = _readBufferLength + i
                    
                    if i > 0 && readBuffer[i - 1] == 0xD {
                        retLength -= 1
                    }
                    
                    let retCStringLength = _readBufferLength + retLength
                    var retCString = UnsafeMutableRawPointer.allocate(bytes: retCStringLength, alignedTo: MemoryLayout<UInt8>.alignment)
                    
                    defer {
                        retCString.deallocate(bytes: retCStringLength, alignedTo: MemoryLayout<UInt8>.alignment)
                    }
                    
                    if _readBuffer != nil {
                        retCString.copyBytes(from: _readBuffer, count: _readBufferLength)
                    }
                    
                    retCString.advanced(by: _readBufferLength).copyBytes(from: buffer, count: retLength)
                    
                    ret = String(data: Data(bytesNoCopy: retCString, count: retCStringLength, deallocator: .none), encoding: encoding)
                    
                    guard ret != nil else {
                        if bufferLength > 0 {
                            _readBuffer = nil
                            _readBufferMemmory = self._resizeIntenalBuffer(_readBufferMemmory, size: bufferLength)
                            _readBuffer = _readBufferMemmory.baseAddress!
                            
                            _readBuffer.advanced(by: _readBufferLength).copyBytes(from: buffer, count: bufferLength)
                            _readBufferLength += bufferLength
                        }
                        
                        throw OFException.invalidEncoding(encoding)
                    }
                    
                    if _readBuffer != nil {
                        _readBufferMemmory.deallocate()
                        _readBuffer = nil
                        _readBufferLength = 0
                    }
                    
                    _readBufferMemmory = UnsafeMutableRawBufferPointer.allocate(count: bufferLength - i - 1)
                    _readBuffer = _readBufferMemmory.baseAddress
                    _readBufferLength = bufferLength - i - 1
                    
                    _readBuffer.copyBytes(from: buffer.advanced(by: i + 1), count: _readBufferLength)
                    _waitingForDelimiter = false
                    
                    return ret
                }
            }
        }
        
        if bufferLength > 0 {
            _readBuffer = nil
            _readBufferMemmory = self._resizeIntenalBuffer(_readBufferMemmory, size: _readBufferLength)
            _readBuffer = _readBufferMemmory.baseAddress
            
            _readBuffer.advanced(by: _readBufferLength).copyBytes(from: buffer, count: bufferLength)
            _readBufferLength += bufferLength
        }
        
        _waitingForDelimiter = true
        
        return nil
    }
    
    open func readLine(withEncoding encoding: String.Encoding = .utf8) throws -> String? {
        var line: String? = nil
        
        while (line = try self.tryReadLine(withEncoding: encoding), line).1 == nil {
            guard try !self.atEndOfStream() else {
                return nil
            }
        }
        
        return line
    }
    
    open func asyncReadLine(withEncoding encoding: String.Encoding = .utf8, _ body: @escaping OFAsyncReadLineBlock) {
        
        StreamObserver.current._addAsyncReadLineForStream(self, encoding: encoding, block: body)
    }
    
    open func tryReadString(tillDelimiter delimiter: String, encoding: String.Encoding = .utf8) throws -> String? {
        var delimiterLength = delimiter.lengthOfBytes(using: encoding)
        
        guard delimiterLength != 0 else {
            throw OFException.invalidArgument()
        }
        
        guard let delimiterCString = delimiter.cString(using: encoding) else {
            throw OFException.invalidArgument()
        }
        
        var ret: String? = nil
        var j = Int(0)
        
        if !_waitingForDelimiter && _readBuffer != nil {
            let readBuffer = _readBuffer.assumingMemoryBound(to: CChar.self)
            
            for i in 0..<_readBufferLength {
                let delimiterIndex = j
                j += 1
                
                if readBuffer[i] != delimiterCString[delimiterIndex] {
                    j = 0
                }
                
                if j == delimiterLength || readBuffer[i] == 0x0 {
                    if readBuffer[i] == 0x0 {
                        delimiterLength = 1
                    }
                    
                    ret = String(data: Data(bytesNoCopy: _readBuffer, count: i + 1 - delimiterLength, deallocator: .none), encoding: encoding)
                    
                    _readBuffer = _readBuffer.advanced(by: i + 1)
                    _readBufferLength -= i + 1
                    _waitingForDelimiter = false
                    
                    return ret
                }
            }
        }
        
        if try self.lowLevelIsAtEndOfStream() {
            guard _readBuffer != nil else {
                _waitingForDelimiter = false
                
                return nil
            }
            
            
        }
        
        let pageSize = NSPageSize()
        var buffer = UnsafeMutableRawPointer.allocate(bytes: pageSize, alignedTo: MemoryLayout<UInt8>.alignment)
        
        defer {
            buffer.deallocate(bytes: pageSize, alignedTo: MemoryLayout<UInt8>.alignment)
        }
        
        let bufferLength = try self.lowLevelRead(into: &buffer, length: pageSize)
        let readBuffer = buffer.assumingMemoryBound(to: CChar.self)
        
        for i in 0..<bufferLength {
            let delimiterIndex = j
            j += 1
            
            if readBuffer[i] != delimiterCString[delimiterIndex] {
                j = 0
            }
            
            if j == delimiterLength || readBuffer[i] == 0x0 {
                if readBuffer[i] == 0x0 {
                    delimiterLength = 1
                }
                
                let retLength = _readBufferLength + i + 1 - delimiterLength
                
                let retCString = UnsafeMutableRawPointer.allocate(bytes: retLength, alignedTo: MemoryLayout<UInt8>.alignment)
                
                defer {
                    retCString.deallocate(bytes: retLength, alignedTo: MemoryLayout<UInt8>.alignment)
                }
                
                if _readBuffer != nil && _readBufferLength <= retLength {
                    retCString.copyBytes(from: _readBuffer, count: _readBufferLength)
                } else if _readBuffer != nil {
                    retCString.copyBytes(from: _readBuffer, count: retLength)
                }
                
                if i >= delimiterLength {
                    retCString.advanced(by: _readBufferLength).copyBytes(from: buffer, count: i + 1 - delimiterLength)
                }
                
                ret = String(data: Data(bytesNoCopy: retCString, count: retLength, deallocator: .none), encoding: encoding)
                
                guard ret != nil else {
                    if bufferLength > 0 {
                        _readBuffer = nil
                        _readBufferMemmory = self._resizeIntenalBuffer(_readBufferMemmory, size: bufferLength)
                        _readBuffer = _readBufferMemmory.baseAddress!
                        
                        _readBuffer.advanced(by: _readBufferLength).copyBytes(from: buffer, count: bufferLength)
                        _readBufferLength += bufferLength
                    }
                    
                    return nil
                }
                
                if _readBuffer != nil {
                    _readBufferMemmory.deallocate()
                    _readBuffer = nil
                    _readBufferLength = 0
                }
                
                _readBufferMemmory = UnsafeMutableRawBufferPointer.allocate(count: bufferLength - i - 1)
                _readBuffer = _readBufferMemmory.baseAddress
                _readBuffer.copyBytes(from: buffer.advanced(by: i + 1), count: bufferLength - i - 1)
                _readBufferLength = bufferLength - i - 1
                
                _waitingForDelimiter = false
                
                return ret
            }
        }
        
        if bufferLength > 0 {
            _readBuffer = nil
            _readBufferMemmory = self._resizeIntenalBuffer(_readBufferMemmory, size: _readBufferLength)
            _readBuffer = _readBufferMemmory.baseAddress
            
            _readBuffer.advanced(by: _readBufferLength).copyBytes(from: buffer, count: bufferLength)
            _readBufferLength += bufferLength
        }
        
        _waitingForDelimiter = true
        
        return nil
    }
    
    open func readString(tillDelimiter delimiter: String, encoding: String.Encoding = .utf8) throws -> String? {
        var ret: String? = nil
        
        while (ret = try self.tryReadString(tillDelimiter: delimiter, encoding: encoding), ret).1 == nil {
            guard try !self.atEndOfStream() else {
                return nil
            }
        }
        
        return ret
    }
    
    @discardableResult
    open func writeString(_ string: String, withEncoding encoding: String.Encoding = .utf8) throws -> Int {
        let bufferLength = string.lengthOfBytes(using: encoding)
        
        guard bufferLength != 0 else {
            throw OFException.invalidArgument()
        }
        
        guard let characters = string.cString(using: encoding) else {
            throw OFException.invalidArgument()
        }
        
        _ = try characters.withUnsafeBytes {
            try self.writeBuffer( $0.baseAddress!, length: bufferLength)
        }
        
        return bufferLength
    }
    
    @discardableResult
    open func writeLine(_ string: String, withEncoding encoding: String.Encoding = .utf8) throws -> Int {
        return try self.writeString(string + "\n", withEncoding: encoding)
    }
    
    @discardableResult
    open func writeString(format: String, _ args: CVarArg...) throws -> Int {
        let res = String(format: format, arguments: args)
        let length = res.lengthOfBytes(using: .utf8)
        
        _ = try res.withCString {
            try self.writeBuffer( $0, length: length)
        }
        
        return length
    }
    
    open func flushWriteBuffer() throws {
        guard _writeBuffer != nil else {
            return
        }
        
        try self.lowLevelWrite(_writeBuffer.baseAddress!, length: _writeBufferLength)
        
        _writeBuffer.deallocate()
        _writeBuffer = nil
        _writeBufferLength = 0
    }
    
    open func close() throws {
        if _writeBuffer != nil {
            _writeBuffer.deallocate()
        }
        
        if _readBufferMemmory != nil {
            _readBuffer = nil
            _readBufferMemmory.deallocate()
        }
        
        _readBufferLength = 0
        _writeBufferLength = 0
        self.writeBuffered = false
    }
    
    open func cancelAsyncRequests() {
        StreamObserver.current._cancelAsyncRequestsForObject(self)
    }
}

internal extension OFStream {
    internal func of_waitForDelimiter() -> Bool {
        return _waitingForDelimiter
    }
}
