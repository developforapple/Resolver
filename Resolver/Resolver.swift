import Foundation
import dnssd

private let dict = SafeDict<Resolver>()

public enum ResolveType: DNSServiceProtocol {
    case ipv4 = 1, ipv6 = 2, any = 3
}

public class Resolver {
    fileprivate static let queue = DispatchQueue(label: "ResolverQueue")
    
    public let hostname: String
    fileprivate let resolveType: ResolveType
    fileprivate let firstResult: Bool
    public var ipv4Result: [String] = []
    public var ipv6Result: [String] = []
    public var result: [String] {
        return ipv4Result + ipv6Result
    }
    
    var cancelled = false
    
    fileprivate var ref: DNSServiceRef?
    fileprivate var id: UnsafeMutablePointer<Int>?
    fileprivate var completionHandler: ((Resolver?, DNSServiceErrorType?)->())!
    fileprivate let timeout: Int
    fileprivate let timer = DispatchSource.makeTimerSource(queue: Resolver.queue)
    
    public static func resolve(hostname: String, qtype: ResolveType = .ipv4, firstResult: Bool = true, timeout: Int = 3, completionHanlder: @escaping (Resolver?, DNSServiceErrorType?)->()) -> Bool {
        let resolver = Resolver(hostname: hostname, qtype: qtype, firstResult: firstResult, timeout: timeout)
        resolver.completionHandler = completionHanlder
        return resolver.resolve()
    }
    
    fileprivate init(hostname: String, qtype: ResolveType, firstResult: Bool, timeout: Int) {
        self.hostname = hostname
        self.resolveType = qtype
        self.firstResult = firstResult
        self.timeout = timeout
    }
    
    fileprivate func resolve() -> Bool {
        guard ref == nil else {
            return false
        }
        
        var result: Bool = false
        Resolver.queue.sync {
            self.id = dict.insert(value: self)
            
            self.timer.scheduleOneshot(deadline: DispatchTime.now() + DispatchTimeInterval.seconds(self.timeout))
            self.timer.setEventHandler(handler: self.timeoutHandler)
            
            result = hostname.withCString { (ptr: UnsafePointer<Int8>) in
                guard DNSServiceGetAddrInfo(&ref, 0, 0, resolveType.rawValue, hostname, { (sdRef, flags, interfaceIndex, errorCode, ptr, address, ttl, context) in
                    // Note this callback block will be called on `Resolver.queue`.
                    
                    guard let resolver = dict.get(context!.bindMemory(to: Int.self, capacity: 1)) else {
                        NSLog("Error: Got some unknown resolver.")
                        return
                    }
                    
                    guard !resolver.cancelled else {
                        return
                    }
                    
                    guard errorCode == DNSServiceErrorType(kDNSServiceErr_NoError) else {
                        resolver.release()
                        resolver.completionHandler(nil, errorCode)
                        return
                    }
                    
                    switch (Int32(address!.pointee.sa_family)) {
                    case AF_INET:
                        var buffer = [Int8](repeating: 0, count: Int(INET_ADDRSTRLEN))
                        _ = buffer.withUnsafeMutableBufferPointer { buf in
                            address?.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { addr in
                                var sin_addr = addr.pointee.sin_addr
                                inet_ntop(AF_INET, &sin_addr, buf.baseAddress, socklen_t(INET_ADDRSTRLEN))
                                let addr = String(cString: buf.baseAddress!)
                                resolver.ipv4Result.append(addr)
                            }
                        }
                    case AF_INET6:
                        var buffer = [Int8](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                        _ = buffer.withUnsafeMutableBufferPointer { buf in
                            address?.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { addr in
                                var sin6_addr = addr.pointee.sin6_addr
                                inet_ntop(AF_INET6, &sin6_addr, buf.baseAddress, socklen_t(INET6_ADDRSTRLEN))
                                let addr = String(cString: buf.baseAddress!)
                                resolver.ipv6Result.append(addr)
                            }
                        }
                    default:
                        break
                    }
                    
                    if (resolver.firstResult || flags & DNSServiceFlags(kDNSServiceFlagsMoreComing) == 0) {
                        resolver.release()
                        return resolver.completionHandler(resolver, nil)
                    }
                }, id) == DNSServiceErrorType(kDNSServiceErr_NoError) else {
                    return false
                }
                
                DNSServiceSetDispatchQueue(self.ref, Resolver.queue)
                self.timer.resume()
                return true
            }
        }
        return result
    }
    
    func timeoutHandler() {
        if !cancelled {
            release()
            completionHandler(nil, DNSServiceErrorType(kDNSServiceErr_Timeout))
        }
    }
    
    func release() {
        cancelled = true
        
        timer.cancel()
        
        if ref != nil {
            DNSServiceRefDeallocate(ref)
            ref = nil
        }
        if id != nil {
            _ = dict.remove(id!)
            id = nil
        }
    }
}
