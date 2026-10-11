import Foundation
let arguments = CommandLine.arguments
var userInfo = ["command":arguments[2]]
if arguments.count > 3 { userInfo["request_id"] = arguments[3] }
DistributedNotificationCenter.default().postNotificationName(Notification.Name("mochi.e2e.command"),object:arguments[1],userInfo:userInfo,deliverImmediately:true)
