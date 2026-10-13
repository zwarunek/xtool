import Foundation

/// Writes a BOM ("Bill of Materials") store, the container format of compiled asset catalogs.
///
/// Layout, matching what CoreUI's actool produces: a 512-byte header area, the data blocks
/// (16-byte aligned), the variables table, then the block index. All BOM metadata is big-endian.
final class BOMWriter {
    private(set) var blocks: [Data] = [Data()]  // block 0 is the null block
    private var variables: [(name: String, block: UInt32)] = []

    /// Leaves hold at most this many entries before the tree grows an index level.
    static let maxLeafEntries = 256

    @discardableResult
    func addBlock(_ data: Data) -> UInt32 {
        blocks.append(data)
        return UInt32(blocks.count - 1)
    }

    func addVariable(_ name: String, block: UInt32) {
        variables.append((name, block))
    }

    /// Adds a B+ tree. `entries` must already be sorted by key in the order readers search them.
    /// With `inlineKeys`, each key is a 32-bit number stored in place of a block index.
    func addTree(_ name: String, entries: [(key: Data, value: Data)], blockSize: UInt32 = 4096, inlineKeys: Bool = false, leafPaddingPerEntry: Int = 0) {
        var leaves: [(block: UInt32, lastKey: UInt32)] = []
        let perLeaf = min(Self.maxLeafEntries, (Int(blockSize) - 12) / 8)
        let chunks: [ArraySlice<(key: Data, value: Data)>] = stride(from: 0, to: max(entries.count, 1), by: perLeaf).map {
            entries[min($0, entries.count)..<min($0 + perLeaf, entries.count)]
        }
        // Reserve leaf block ids first so each leaf can point at its neighbors.
        let leafIDs = chunks.map { _ in addBlock(Data()) }
        for (i, chunk) in chunks.enumerated() {
            var pairs: [(UInt32, UInt32)] = []
            for entry in chunk {
                let keyRef: UInt32
                if inlineKeys {
                    var r = ByteReader(entry.key)
                    keyRef = (try? r.u32le()) ?? 0
                } else {
                    keyRef = addBlock(entry.key)
                }
                let valueRef = addBlock(entry.value)
                pairs.append((valueRef, keyRef))
            }
            var node = ByteWriter()
            node.u16be(1)
            node.u16be(UInt16(pairs.count))
            node.u32be(i + 1 < leafIDs.count ? leafIDs[i + 1] : 0)
            node.u32be(i > 0 ? leafIDs[i - 1] : 0)
            for (v, k) in pairs {
                node.u32be(v)
                node.u32be(k)
            }
            let padded = max(Int(blockSize) + leafPaddingPerEntry * pairs.count, node.count)
            node.zeros(padded - node.count)
            blocks[Int(leafIDs[i])] = node.data
            leaves.append((leafIDs[i], pairs.last?.1 ?? 0))
        }

        let root: UInt32
        if leaves.count == 1 {
            root = leaves[0].block
        } else {
            var node = ByteWriter()
            node.u16be(0)
            node.u16be(UInt16(leaves.count - 1))
            node.u32be(0)
            node.u32be(0)
            for (i, leaf) in leaves.enumerated() {
                node.u32be(leaf.block)
                node.u32be(i == leaves.count - 1 ? 0 : leaf.lastKey)
            }
            node.zeros(max(Int(blockSize), node.count) - node.count)
            root = addBlock(node.data)
        }

        var header = ByteWriter()
        header.tag("tree")
        header.u32be(1)
        header.u32be(root)
        header.u32be(blockSize)
        header.u32be(UInt32(entries.count))
        header.u8(inlineKeys ? 1 : 0)
        addVariable(name, block: addBlock(header.data))
    }

    func serialize() -> Data {
        var out = ByteWriter(capacity: blocks.reduce(4096) { $0 + $1.count + 16 })
        out.zeros(512)
        var addresses: [(UInt32, UInt32)] = [(0, 0)]
        for block in blocks.dropFirst() {
            out.align(16)
            addresses.append((UInt32(out.count), UInt32(block.count)))
            out.bytes(block)
        }
        out.align(16)
        let varsOffset = out.count
        out.u32be(UInt32(variables.count))
        for v in variables {
            out.u32be(v.block)
            let name = Array(v.name.utf8)
            out.u8(UInt8(name.count))
            out.bytes(name)
        }
        let varsLength = out.count - varsOffset
        out.align(16)
        let indexOffset = out.count
        out.u32be(UInt32(addresses.count))
        for (address, length) in addresses {
            out.u32be(address)
            out.u32be(length)
        }
        // Free list: no free ranges, two empty slots.
        out.u32be(0)
        out.zeros(16)
        let indexLength = out.count - indexOffset

        var header = ByteWriter()
        header.bytes(Array("BOMStore".utf8))
        header.u32be(1)
        header.u32be(UInt32(blocks.count - 1))
        header.u32be(UInt32(indexOffset))
        header.u32be(UInt32(indexLength))
        header.u32be(UInt32(varsOffset))
        header.u32be(UInt32(varsLength))
        var data = out.data
        data.replaceSubrange(0..<header.count, with: header.data)
        return data
    }
}

/// Reads a BOM store. Used by tests and `actool --dump-car`.
struct BOMReader {
    let data: Data
    private(set) var blockTable: [(address: Int, length: Int)] = []
    private(set) var variables: [(name: String, block: UInt32)] = []

    enum Error: Swift.Error, CustomStringConvertible {
        case notABOM
        case badBlock(UInt32)
        case missingVariable(String)
        case badTree(String)

        var description: String {
            switch self {
            case .notABOM: return "not a BOM store"
            case .badBlock(let b): return "bad BOM block \(b)"
            case .missingVariable(let v): return "missing BOM variable \(v)"
            case .badTree(let v): return "malformed BOM tree \(v)"
            }
        }
    }

    init(_ data: Data) throws {
        self.data = data
        guard data.count >= 32, data.prefix(8) == Data("BOMStore".utf8) else { throw Error.notABOM }
        var r = ByteReader(data, offset: 8)
        _ = try r.u32be()
        _ = try r.u32be()
        let indexOffset = Int(try r.u32be())
        _ = try r.u32be()
        let varsOffset = Int(try r.u32be())
        var ir = ByteReader(data, offset: indexOffset)
        let count = Int(try ir.u32be())
        for _ in 0..<count {
            let address = Int(try ir.u32be())
            let length = Int(try ir.u32be())
            blockTable.append((address, length))
        }
        var vr = ByteReader(data, offset: varsOffset)
        let nvars = Int(try vr.u32be())
        for _ in 0..<nvars {
            let block = try vr.u32be()
            let length = Int(try vr.u8())
            let name = String(decoding: try vr.bytes(length), as: UTF8.self)
            variables.append((name, block))
        }
    }

    func block(_ index: UInt32) throws -> Data {
        guard Int(index) < blockTable.count else { throw Error.badBlock(index) }
        let (address, length) = blockTable[Int(index)]
        guard address + length <= data.count else { throw Error.badBlock(index) }
        return data.subdata(in: (data.startIndex + address)..<(data.startIndex + address + length))
    }

    func variable(_ name: String) throws -> Data {
        guard let v = variables.first(where: { $0.name == name }) else { throw Error.missingVariable(name) }
        return try block(v.block)
    }

    func hasVariable(_ name: String) -> Bool { variables.contains { $0.name == name } }

    /// Returns all (key, value) pairs of a tree in leaf order. Inline-key trees return the key as 4 little-endian bytes.
    func tree(_ name: String) throws -> [(key: Data, value: Data)] {
        let header = try variable(name)
        var r = ByteReader(header)
        guard try r.tag() == "tree" else { throw Error.badTree(name) }
        _ = try r.u32be()
        let root = try r.u32be()
        _ = try r.u32be()
        _ = try r.u32be()
        let inline = (try? r.u8()) == 1
        var out: [(Data, Data)] = []
        try walk(root, inline: inline, into: &out, depth: 0, name: name)
        return out
    }

    private func walk(_ index: UInt32, inline: Bool, into out: inout [(Data, Data)], depth: Int, name: String) throws {
        guard depth < 16 else { throw Error.badTree(name) }
        var r = ByteReader(try block(index))
        let isLeaf = try r.u16be()
        let count = Int(try r.u16be())
        _ = try r.u32be()
        _ = try r.u32be()
        if isLeaf != 0 {
            for _ in 0..<count {
                let v = try r.u32be()
                let k = try r.u32be()
                let key: Data
                if inline {
                    var w = ByteWriter()
                    w.u32le(k)
                    key = w.data
                } else {
                    key = try block(k)
                }
                out.append((key, try block(v)))
            }
        } else {
            for _ in 0...count {
                let child = try r.u32be()
                _ = try r.u32be()
                try walk(child, inline: inline, into: &out, depth: depth + 1, name: name)
            }
        }
    }
}
