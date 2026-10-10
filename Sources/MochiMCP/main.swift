import Foundation
import Darwin
import MochiAutomation

let socketPath = ProcessInfo.processInfo.environment["MOCHI_CONTROL_SOCKET"] ?? LocalControl.defaultPath
let server = MochiMCPProtocol(bridge: { try LocalControl.request($0,path:socketPath) },
                              diagnostics: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) })
// Bounded newline framing. Stdout carries protocol responses only; diagnostics go to stderr.
var framer = MCPStdioFramer()
func answer(_ line: MCPStdioFramer.Line) {
    let response: Data?
    switch line {
    case .request(let data): response = server.respond(data)
    case .oversized: response = server.oversizedResponse()
    }
    if let response { FileHandle.standardOutput.write(response + Data([10])) }
}
// read(2) returns as soon as any bytes arrive, so an interactive client is answered without waiting for more input.
var buffer = [UInt8](repeating:0,count:65536)
while true {
    let count = Darwin.read(STDIN_FILENO,&buffer,buffer.count)
    if count < 0 { if errno == EINTR { continue }; break }
    if count == 0 { break }
    for line in framer.feed(Data(buffer[0..<count])) { answer(line) }
}
if let last = framer.finish() { answer(last) }
