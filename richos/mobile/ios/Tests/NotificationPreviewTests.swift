import Foundation

@main struct NotificationPreviewTests {
    static func main() throws {
        let data = try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))
        let fixture = try JSONSerialization.jsonObject(with:data) as! [String:Any]
        let key = NotificationPreview.decode(fixture["key"] as! String)!
        let payload = fixture["payload"] as! [String:Any]
        let text = try NotificationPreview.decrypt(payload,key:key)
        precondition(text == fixture["text"] as! String,"WebCrypto and CryptoKit must agree")
        precondition((try? NotificationPreview.decrypt(payload,key:Data(repeating:0,count:32))) == nil,"Wrong key must fail closed")
        var tampered = payload
        var refs = payload["richos"] as! [String:String];refs["event"] = String(repeating:"d",count:64);tampered["richos"] = refs
        precondition((try? NotificationPreview.decrypt(tampered,key:key)) == nil,"A preview cannot be moved to another reply")
        var preview = payload["preview"] as! [String:Any];preview["body"] = String(repeating:"a",count:2000);tampered = payload;tampered["preview"] = preview
        precondition((try? NotificationPreview.decrypt(tampered,key:key)) == nil,"Oversized ciphertext must be refused")
        precondition((try? NotificationPreview.decrypt([:],key:key)) == nil,"Generic alerts have no preview")
        print("Notification preview: 5 checks passed")
    }
}
