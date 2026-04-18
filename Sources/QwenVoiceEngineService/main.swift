import Foundation

let listener = NSXPCListener.service()
listener.delegate = EngineServiceHost.shared
listener.resume()
RunLoop.current.run()
