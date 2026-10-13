import Foundation

/// Writes XML property lists directly (swift-corelibs-foundation rejects some Swift collection types).
public enum PlistXML {
    public static func encode(_ value: Any) -> Data {
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\">\n"
        write(value, into: &out)
        out += "</plist>\n"
        return Data(out.utf8)
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    static func write(_ value: Any, into out: inout String) {
        switch value {
        case let s as String:
            out += "<string>\(escape(s))</string>\n"
        case let b as Bool:
            out += b ? "<true/>\n" : "<false/>\n"
        case let i as Int:
            out += "<integer>\(i)</integer>\n"
        case let d as Double:
            out += "<real>\(d)</real>\n"
        case let data as Data:
            out += "<data>\(data.base64EncodedString())</data>\n"
        case let dict as [String: Any]:
            if dict.isEmpty {
                out += "<dict/>\n"
                return
            }
            out += "<dict>\n"
            for key in dict.keys.sorted() {
                out += "<key>\(escape(key))</key>\n"
                write(dict[key]!, into: &out)
            }
            out += "</dict>\n"
        case let array as [Any]:
            if array.isEmpty {
                out += "<array/>\n"
                return
            }
            out += "<array>\n"
            for item in array { write(item, into: &out) }
            out += "</array>\n"
        default:
            out += "<string>\(escape("\(value)"))</string>\n"
        }
    }
}
