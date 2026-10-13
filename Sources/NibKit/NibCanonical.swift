import Foundation

/// A text form of a nib for comparing two nibs built from the same xib.
///
/// Objects reached through reference keys (constraint items, connection ends, ...) print as a short
/// signature instead of being expanded again, and the arrays whose order ibtool takes from hash tables
/// (constraints, the objects list, trait storage candidates) are sorted.
public enum NibCanonical {
    static let referenceKeys: Set<String> = [
        "NSFirstItem", "NSSecondItem", "UISource", "UIDestination", "UIObject", "UILayoutGuideOwningView",
        "UIContentView",
    ]
    static let unorderedKeys: Set<String> = ["UIViewAutolayoutConstraints", "UINibObjectsKey", "UIRelationshipCandidates"]
    static let valueClasses: Set<String> = [
        "NSString", "NSNumber", "UIColor", "UIFont", "NSValue", "UIFontDescriptor", "NSDictionary", "NSMutableDictionary",
    ]

    public static func lines(_ root: NibObject) -> [String] {
        render(root, depth: 0, stack: [])
    }

    /// Lines that differ between two canonical forms, as a unified-diff-like list ("-" reference, "+" candidate).
    public static func difference(reference: NibObject, candidate: NibObject) -> [String] {
        let a = lines(reference), b = lines(candidate)
        let diff = b.difference(from: a)
        return diff.map { change in
            switch change {
            case .insert(_, let line, _): return "+" + line
            case .remove(_, let line, _): return "-" + line
            }
        }
    }

    static func format(_ value: Double) -> String {
        String(format: "%.6g", value)
    }

    static func primitive(_ value: NibValue) -> String {
        switch value {
        case .int(let v): return "int \(v)"
        case .bool(let b): return b ? "true" : "false"
        case .float(let f): return "f " + format(Double(f))
        case .double(let d): return "d " + format(d)
        case .null: return "nil"
        case .object: return "object"
        case .data(let bytes):
            if bytes.first == 0x07, bytes.count > 1, (bytes.count - 1) % 8 == 0 {
                let values = stride(from: 1, to: bytes.count, by: 8).map { i -> String in
                    let bits = bytes[i..<i + 8].enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
                    return format(Double(bitPattern: bits))
                }
                return "doubles " + values.joined(separator: ",")
            }
            return "data " + quoted(bytes)
        }
    }

    static func quoted(_ bytes: [UInt8]) -> String {
        if let s = String(bytes: bytes, encoding: .utf8) { return "'\(s)'" }
        return "0x" + bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func stringValue(_ object: NibObject) -> String {
        if case .data(let bytes)? = object["NS.bytes"] { return quoted(bytes) }
        return "?"
    }

    static func signature(_ object: NibObject) -> String {
        var parts = [object.className]
        for (key, value) in object.values {
            switch (key, value) {
            case ("UIBounds", _), ("UICenter", _), ("NSFirstAttribute", _), ("NSSecondAttribute", _), ("NSConstant", _), ("UITag", _):
                parts.append("\(key)=\(primitive(value))")
            case ("UIClassName", .object(let s)), ("UILayoutGuideIdentifier", .object(let s)),
                 ("NSLayoutIdentifier", .object(let s)), ("UIProxiedObjectIdentifier", .object(let s)):
                parts.append("\(key)=\(stringValue(s))")
            case ("NSFirstItem", .object(let item)), ("NSSecondItem", .object(let item)):
                parts.append("\(key)=\(item.className)")
            default:
                break
            }
        }
        return "<" + parts.joined(separator: " ") + ">"
    }

    static func render(_ object: NibObject, depth: Int, stack: Set<ObjectIdentifier>) -> [String] {
        let pad = String(repeating: "  ", count: depth)
        if stack.contains(ObjectIdentifier(object)) { return [pad + "^" + signature(object)] }
        if object.className == "NSString" { return [pad + "NSString " + stringValue(object)] }
        var stack = stack
        stack.insert(ObjectIdentifier(object))
        var lines = [pad + object.className]
        for (key, value) in object.values {
            guard case .object(let child) = value else {
                lines.append("\(pad)  \(key): \(primitive(value))")
                continue
            }
            if unorderedKeys.contains(key) {
                var elements: [[String]] = []
                for (elementKey, elementValue) in child.values {
                    guard elementKey == "UINibEncoderEmptyKey" || elementKey.hasPrefix("NS.object."),
                          case .object(let element) = elementValue else { continue }
                    elements.append(key == "UINibObjectsKey" ? [signature(element)] : render(element, depth: depth + 2, stack: stack))
                }
                elements.sort { $0.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
                    < $1.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n") }
                lines.append("\(pad)  \(key): \(child.className) (sorted, \(elements.count))")
                lines.append(contentsOf: elements.joined())
                continue
            }
            if referenceKeys.contains(key) && !valueClasses.contains(child.className) {
                lines.append("\(pad)  \(key): \(signature(child))")
                continue
            }
            var sub = render(child, depth: depth + 1, stack: stack)
            sub[0] = "\(pad)  \(key): " + sub[0].trimmingCharacters(in: .whitespaces)
            lines.append(contentsOf: sub)
        }
        return lines
    }
}
