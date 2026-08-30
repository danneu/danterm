// Byte-oriented stream reduction that joins incremental UTF-8 with bounded VT recognition.

/// One scalar to print, with the classification the stream already read for it, when it read one.
///
/// The stream classifies every scalar it decodes to decide whether a run may hold it, so the
/// scalar it hands over as a single print has been classified once already; carrying the record
/// is what keeps the printer from reading the same table row a second time (`research/39/D9`).
/// A scalar the stream never classified -- one from the generic path, after an escape or a chunk
/// tail -- carries nil, and the printer looks it up as before.
///
/// The classification is a pure function of the scalar, so it is a cache, not part of the token:
/// two prints of the same scalar are the same token whether or not either carries one, and
/// equality says so. What the cache is worth is measured on the grid, not here -- a wrong record
/// would place a different cell, which the whole-terminal equivalence tests read.
struct PrintedScalar: Sendable, ExpressibleByUnicodeScalarLiteral {
    let scalar: Unicode.Scalar
    let classification: TerminalUnicodeClassification?

    init(_ scalar: Unicode.Scalar, classification: TerminalUnicodeClassification? = nil) {
        self.scalar = scalar
        self.classification = classification
    }

    /// Lets a token-stream expectation name the scalar it expects and nothing else.
    init(unicodeScalarLiteral value: Unicode.Scalar) {
        self.init(value)
    }
}

extension PrintedScalar: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.scalar == rhs.scalar
    }
}

/// Which writer a stretch's scalar belongs to, decided once by the stream.
///
/// The stream classifies every scalar it admits, so the writer that can stamp it is already known
/// when it is stored. Carrying the answer as one byte is what lets the printer find a segment's
/// extent by comparing kinds instead of re-reading a classification record per scalar
/// (`research/39/D10`).
enum TerminalStretchSegmentKind: UInt8, Sendable {
    /// A printable ASCII byte, which prints through the invoked GL character set.
    case glByte
    /// A bulk-printable scalar one cell wide.
    case bulkNarrow
    /// A bulk-printable scalar two cells wide.
    case bulkWide
    /// Everything else -- a joiner, a mark, an emoji base -- which costs one single-scalar print.
    case single
}

/// The scratch a text stretch fills: one entry per scalar in each span, at the same offset.
///
/// This is what a stretch action hands over -- the range in the action names the bytes, and these
/// are the scalars they became (`research/39/D9`). Two spans rather than one span of pairs,
/// because the writers read only scalars and the segment scan reads only kinds: apart, the scalar
/// span keeps exactly the four-byte shape the bulk writers have always loaded, and a stretch costs
/// a bulk scalar one extra byte rather than a wider load. Together in one element they cost every
/// bulk scalar a wider store and a strided load, which is what the `unicode` arm reads.
///
/// Two spans, but one allocation: `withScratch` carves both out of a single temporary buffer.
/// A feed pays for the scratch whether or not it holds any text, so a second allocation is a cost
/// every arm carries and only the text arms earn back -- which is what the `csi` arm reads.
struct TerminalStretchScratch {
    let scalars: UnsafeMutableBufferPointer<Unicode.Scalar>
    let kinds: UnsafeMutableBufferPointer<TerminalStretchSegmentKind>

    /// Bytes one allocation must hold to back both spans at `TerminalInputStream.stretchScalarCap`
    /// entries each. The scalar span comes first, so the buffer's own alignment serves it and the
    /// single-byte kinds need none.
    static var byteCount: Int {
        TerminalInputStream.stretchScalarCap
            * (MemoryLayout<Unicode.Scalar>.stride + MemoryLayout<TerminalStretchSegmentKind>.stride)
    }

    /// Lends one scratch for the length of `body`, from a single temporary allocation.
    ///
    /// The only way a scratch is made. Whoever feeds bytes takes one for the whole feed, and every
    /// stretch in that feed overwrites the last one's entries.
    static func withScratch<R>(_ body: (TerminalStretchScratch) -> R) -> R {
        withUnsafeTemporaryAllocation(
            byteCount: byteCount,
            alignment: MemoryLayout<Unicode.Scalar>.alignment
        ) { storage in
            let scalarBytes = TerminalInputStream.stretchScalarCap * MemoryLayout<Unicode.Scalar>.stride
            let scalars = UnsafeMutableRawBufferPointer(rebasing: storage[..<scalarBytes])
                .bindMemory(to: Unicode.Scalar.self)
            let kinds = UnsafeMutableRawBufferPointer(rebasing: storage[scalarBytes...])
                .bindMemory(to: TerminalStretchSegmentKind.self)
            return body(TerminalStretchScratch(scalars: scalars, kinds: kinds))
        }
    }

    /// Stores one scalar and the writer it belongs to at the same offset in both spans.
    func initializeElement(at offset: Int, to scalar: Unicode.Scalar, kind: TerminalStretchSegmentKind) {
        scalars.initializeElement(at: offset, to: scalar)
        kinds.initializeElement(at: offset, to: kind)
    }
}

/// Carries scalar and control actions from stream recognition into the terminal grid reducer.
enum TerminalStreamAction: Equatable, Sendable {
    /// A maximal run of printable ASCII, as a range into the chunk being fed.
    ///
    /// The parser recognizes multi-byte units already, and this is one more: input varies at the
    /// granularity of a run of plain text, so the grid should be told about a run rather than
    /// rediscover it a character at a time (`research/33/T8`). A range rather than the bytes
    /// keeps the action POD and copies nothing; it is only meaningful to the caller that supplied
    /// the chunk, which is the same call that receives it.
    ///
    /// Semantically this is one *GL print* per byte in the range -- the parser tests state the
    /// token stream that way and `expandedFeed` expands it -- so no caller may treat the run as
    /// a unit the character path could not produce. A GL print is not the same as `.print`: the
    /// grid reducer translates each byte through the invoked character set, while `.print`
    /// carries an already-decoded scalar that no character set touches.
    case printASCIIRun(Range<Int>)
    /// A maximal stretch of printable text that admitted at least one non-ASCII scalar.
    ///
    /// The stretch is the action boundary for text of every classification: printable ASCII bytes
    /// and complete well-formed non-ASCII sequences run together into one token, so the dispatch,
    /// the damage snapshot and the action's own construction are paid once for a whole stretch of
    /// text rather than once per cluster piece (`research/39/D10`). It ends at a control byte, an
    /// escape, an ignored C1 scalar, a sequence the one-step decoder cannot answer, or the scratch
    /// cap. A stretch that never left printable ASCII is a `printASCIIRun` instead, which carries
    /// no scratch and so has no cap.
    ///
    /// Semantically this is one GL print per ASCII entry and one `.print` per other scalar, which
    /// is what `expandedFeed` expands it to. The printer, not the stream, decides where one
    /// writer's segment ends inside it.
    ///
    /// The scalars are the first `scalarCount` entries of the scratch the caller passed to
    /// `nextAction`, each beside the segment kind its classification implies: the stream decoded
    /// and classified them once, so the printer reads neither the range's bytes nor the
    /// classification table to pick a writer for them (`research/39/D9`). The range stays because
    /// it is what makes this a
    /// statement about the chunk -- which bytes became this token -- and it is the only
    /// independent account of the stretch's scalars a test can hold the scratch against. It is
    /// read only while the scratch still holds this action's scalars, which is until the next
    /// `nextAction` call.
    case printTextStretch(Range<Int>, scalarCount: Int)
    case print(PrintedScalar)
    case execute(UInt8)
    case escape(UInt8)
    case escapeSequence(EscapeSequence)
    case csi(CSISequence)
    case osc([UInt8])
    /// A completed DCS sequence on a route the terminal dispatches; other DCS families never
    /// reach the grid reducer at all.
    case dcs(DCSSequence)
}

/// Owns all pending ingestion state so feeds remain deterministic and value-semantic.
struct TerminalInputStream: Equatable, Sendable {
    private var decoder = UTF8Decoder()
    private var absorber = EscapeAbsorber()

    /// Returns the unfinished byte prefix that recreates this stream reducer's next-byte state.
    var synchronizationPrefix: [UInt8] {
        decoder.synchronizationPrefix + absorber.synchronizationPrefix
    }

    /// The most scalars one `printTextStretch` action may carry, and so the size of the scratch
    /// the caller lends `nextAction`.
    ///
    /// The scratch is a fixed size because it must not grow with the input, so the probe stops
    /// here and opens the next stretch on the following call; a longer stretch becomes several
    /// actions that stamp the same cells (`research/39/D9`, AR3). 1024 is the widest grid the app
    /// can ask for, so no row segment in the app is ever split by this.
    static let stretchScalarCap = 1024

    /// Printable ASCII: the bytes that decode to themselves and print as one narrow cell.
    ///
    /// 0x7F is deliberately outside it -- DEL is an `.execute` -- and so is 0x1B, which starts an
    /// escape.
    static func isPrintableASCII(_ byte: UInt8) -> Bool {
        byte >= 0x20 && byte <= 0x7E
    }

    /// Identifies decoded protocol controls that ground state consumes without an action.
    static func isIgnoredDecodedScalar(_ scalar: Unicode.Scalar) -> Bool {
        (0x80...0x9F).contains(scalar.value)
    }

    /// Recognizes the next action in `bytes` starting at `index`, advancing `index` over exactly
    /// the bytes that action consumed, and returns nil once the chunk is exhausted. Unfinished
    /// UTF-8 and VT sequences stay in `self` for the next chunk, so feeding is chunk-invariant.
    ///
    /// The caller owns the loop, and that is the whole point: `Terminal.feed` applies each action
    /// to the grid before asking for the next one, so the token stream is never materialized as an
    /// array (`research/33/F9` sized the one this replaced at 60-80x the corpus's own byte count).
    /// A sink-closure form would put grid mutation inside a call that is already mutating
    /// `Terminal.inputStream`, which is overlapping access to `self`; storing the chunk and a
    /// position on the stream itself would put mid-feed state into a value that is `Equatable`
    /// and compared between feeds. Both are avoided by leaving the position on the caller's stack.
    ///
    /// A byte the decoder does not consume -- the byte that proved a truncated sequence malformed
    /// -- leaves `index` where it is and is re-offered on the next call, which is how one byte can
    /// produce a replacement scalar and then its own action.
    ///
    /// `scratch` is where a `printTextStretch` leaves the scalars it decoded, so the caller stamps
    /// them without turning the stretch's bytes back into scalars. Each of its spans must hold
    /// `stretchScalarCap` elements, and it is lent, not owned: one scratch serves a whole feed,
    /// each stretch overwrites the last one's entries, and the caller must be done with an
    /// action's scalars before it asks for the next action. Passing the buffers rather than
    /// storing them is what keeps reading a scalar a plain load -- a stored reference would box
    /// the state and put an exclusivity check on every read (`research/39/D8` measured that cost
    /// directly).
    mutating func nextAction(
        in bytes: UnsafeBufferPointer<UInt8>,
        from index: inout Int,
        into scratch: TerminalStretchScratch
    ) -> TerminalStreamAction? {
        while index < bytes.count {
            let byte = bytes[index]
            // Ground state with an idle decoder is the only condition under which a printable
            // ASCII byte is exactly one printable ASCII scalar and a complete sequence decodes
            // without the resumable decoder, and it stays true for as long as the stretch does,
            // because neither the absorber nor the decoder is consulted inside it. Returning the
            // whole stretch is what amortizes this per-token call boundary and everything the
            // caller pays per action (`research/33/F15`, `research/39/D10`).
            if absorber.isGround, decoder.isIdle,
               Self.isPrintableASCII(byte) || byte >= 0x80 {
                let start = index
                var probeIndex = index
                // Printable ASCII costs the scratch nothing while nothing else has joined the
                // stretch, so a stretch that never leaves ASCII stays a byte range with no cap
                // (AR2). Scanning that prefix here keeps it the tight loop it has always been:
                // the mixed loop below is entered only once the prefix has ended, so nothing the
                // scratch needs is tested per ASCII byte.
                while probeIndex < bytes.count, Self.isPrintableASCII(bytes[probeIndex]) {
                    probeIndex += 1
                }
                // The last byte the stretch admitted. It trails `probeIndex`, which walks into a
                // sequence the stretch may end up refusing.
                var stretchEnd = probeIndex
                var scalarCount = 0
                // False until a non-ASCII scalar joins and moves the prefix into the scratch.
                var carriesScratch = false

                stretch: while probeIndex < bytes.count {
                    let probeByte = bytes[probeIndex]
                    // Reached only after a non-ASCII scalar has joined, because the prefix scan
                    // above consumed every printable ASCII byte before this loop began.
                    if Self.isPrintableASCII(probeByte) {
                        guard scalarCount < Self.stretchScalarCap else { break stretch }
                        scratch.initializeElement(
                            at: scalarCount,
                            to: Unicode.Scalar(probeByte),
                            kind: .glByte
                        )
                        scalarCount += 1
                        probeIndex += 1
                        stretchEnd = probeIndex
                        continue
                    }
                    guard probeByte >= 0x80 else { break stretch }
                    var scalarEnd = probeIndex
                    // A sequence the one-step decoder cannot answer -- the chunk tail, or
                    // malformed bytes -- ends the stretch on its first byte, so `decoder` reads it
                    // on the generic path below and its replacement and resumption behavior is the
                    // only thing that answers it.
                    guard let scalar = decodeWellFormedUTF8Scalar(in: bytes, from: &scalarEnd)
                    else { break stretch }
                    // A protocol control ground state drops is not text, so it ends the stretch
                    // and is consumed by the generic path on the next call.
                    if Self.isIgnoredDecodedScalar(scalar) { break stretch }
                    if carriesScratch == false {
                        // The stretch has to carry scalars from here on, so the ASCII prefix it
                        // admitted as bytes moves into the scratch. It moves whole or not at all:
                        // a prefix the scratch cannot hold ends the stretch as an ASCII run, and
                        // this scalar opens the next one.
                        let asciiCount = stretchEnd - start
                        guard asciiCount < Self.stretchScalarCap else { break stretch }
                        for offset in 0..<asciiCount {
                            scratch.initializeElement(
                                at: offset,
                                to: Unicode.Scalar(bytes[start + offset]),
                                kind: .glByte
                            )
                        }
                        scalarCount = asciiCount
                        carriesScratch = true
                    } else {
                        // The scratch is what carries the stretch's scalars, so the stretch ends
                        // where the scratch does. The bytes are untouched, so the next call
                        // reopens a stretch on them and stamps the same cells.
                        guard scalarCount < Self.stretchScalarCap else { break stretch }
                    }
                    scratch.initializeElement(
                        at: scalarCount,
                        to: scalar,
                        kind: terminalUnicodeClassification(for: scalar).stretchSegmentKind
                    )
                    scalarCount += 1
                    probeIndex = scalarEnd
                    stretchEnd = probeIndex
                }

                if stretchEnd > start {
                    index = stretchEnd
                    return carriesScratch
                        ? .printTextStretch(start..<stretchEnd, scalarCount: scalarCount)
                        : .printASCIIRun(start..<stretchEnd)
                }
                // The stretch admitted nothing, so this byte is one the generic paths below own.
            }

            guard absorber.isGround else {
                index += 1
                guard let event = absorber.consume(byte) else { continue }
                switch event {
                case let .execute(control):
                    return .execute(control)
                case let .escape(final):
                    return .escape(final)
                case let .escapeSequence(sequence):
                    return .escapeSequence(sequence)
                case let .csi(sequence):
                    return .csi(sequence)
                case let .osc(payload):
                    return .osc(payload)
                case let .dcs(sequence):
                    return .dcs(sequence)
                }
            }

            let result = decoder.next(byte)
            if result.consumed {
                index += 1
            }
            guard let scalar = result.scalar else { continue }
            if Self.isIgnoredDecodedScalar(scalar) { continue }

            switch scalar.value {
            case 0x1B:
                absorber.startEscape()
            case 0x00...0x1F, 0x7F:
                return .execute(UInt8(scalar.value))
            default:
                // The generic path never classifies, so this scalar carries no record: it is
                // reached only where the stretch probe could not go, and classifying here would
                // be the second read the stretch's carry exists to remove, not the first.
                return .print(PrintedScalar(scalar))
            }
        }

        return nil
    }
}
