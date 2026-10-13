import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// A minimal element tree for Interface Builder documents.
public final class XMLElement2 {
    public let name: String
    public let attributes: [String: String]
    public private(set) var children: [XMLElement2] = []
    public private(set) weak var parent: XMLElement2?
    public let line: Int
    public internal(set) var text: String?

    init(name: String, attributes: [String: String], line: Int) {
        self.name = name
        self.attributes = attributes
        self.line = line
    }

    func append(_ child: XMLElement2) {
        child.parent = self
        children.append(child)
    }

    public subscript(attribute: String) -> String? { attributes[attribute] }

    public func children(named name: String) -> [XMLElement2] { children.filter { $0.name == name } }
    public func child(named name: String) -> XMLElement2? { children.first { $0.name == name } }
    /// The child element with the given `key` attribute (Interface Builder's way of naming properties).
    public func child(key: String) -> XMLElement2? { children.first { $0["key"] == key } }
    public func child(named name: String, key: String) -> XMLElement2? {
        children.first { $0.name == name && $0["key"] == key }
    }

    public func bool(_ attribute: String) -> Bool? {
        guard let v = attributes[attribute] else { return nil }
        return v == "YES"
    }

    public func double(_ attribute: String) -> Double? {
        attributes[attribute].flatMap(Double.init)
    }
}

public enum XMLTreeError: Error, CustomStringConvertible {
    case parse(String, line: Int)

    public var description: String {
        switch self {
        case .parse(let message, let line): return "line \(line): \(message)"
        }
    }
}

final class XMLTreeBuilder: NSObject, XMLParserDelegate {
    var stack: [XMLElement2] = []
    var root: XMLElement2?
    weak var parser: XMLParser?

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let element = XMLElement2(name: elementName, attributes: attributeDict, line: parser.lineNumber)
        if let top = stack.last { top.append(element) } else { root = element }
        stack.append(element)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard let top = stack.last else { return }
        top.text = (top.text ?? "") + string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        stack.removeLast()
    }

    static func parse(_ data: Data) throws -> XMLElement2 {
        let parser = XMLParser(data: data)
        let builder = XMLTreeBuilder()
        parser.delegate = builder
        guard parser.parse(), let root = builder.root else {
            throw XMLTreeError.parse(parser.parserError.map { "\($0)" } ?? "invalid XML", line: parser.lineNumber)
        }
        return root
    }
}
