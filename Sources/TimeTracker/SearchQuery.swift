import Foundation

/// A tiny boolean search language for the entry-list filter.
///
/// A query is a sequence of **terms**, each matched as a case-insensitive substring against a
/// haystack (an entry's description + project name). Terms combine with:
///
///   - `&`   — AND (also *implied* between adjacent terms, so `meet john` == `meet & john`)
///   - `|`   — OR
///   - `!`   — NOT (unary prefix)
///   - `( )` — grouping
///
/// Precedence, tightest first: `!`  >  `&` (and implicit AND)  >  `|`.
/// So `a b | c` parses as `(a & b) | c`, and `!a & b` as `(!a) & b`.
///
/// Parsing is deliberately lenient: leading/dangling operators, a stray `!`, and unbalanced
/// parentheses never fail — they degrade to "match everything" fragments so a half-typed query
/// keeps showing results instead of blanking the list mid-keystroke.
struct SearchQuery {
    /// Whether the query contains at least one real term. When false there is nothing to filter by
    /// (empty box, or only operators/parens) and callers should show every entry.
    let isActive: Bool

    private let root: Node

    init(_ raw: String) {
        let tokens = Self.tokenize(raw)
        isActive = tokens.contains { token in
            if case .term = token { return true }
            return false
        }
        var parser = Parser(tokens: tokens)
        root = parser.parseOr()
    }

    /// True when `haystack` satisfies the query. `haystack` is lowercased here; terms were
    /// lowercased at parse time.
    func matches(_ haystack: String) -> Bool {
        root.matches(haystack.lowercased())
    }

    // MARK: - AST

    private indirect enum Node {
        case term(String)      // non-empty, already lowercased
        case not(Node)
        case and(Node, Node)
        case or(Node, Node)
        case all               // matches everything (empty box / recovered fragment)

        func matches(_ haystack: String) -> Bool {
            switch self {
            case .all: return true
            case .term(let t): return haystack.contains(t)
            case .not(let n): return !n.matches(haystack)
            case .and(let l, let r): return l.matches(haystack) && r.matches(haystack)
            case .or(let l, let r): return l.matches(haystack) || r.matches(haystack)
            }
        }
    }

    // MARK: - Tokenizer

    private enum Token: Equatable {
        case term(String)
        case and, or, not, lparen, rparen
    }

    private static func tokenize(_ raw: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        func flush() {
            if !current.isEmpty { tokens.append(.term(current)); current = "" }
        }
        for ch in raw.lowercased() {
            switch ch {
            case "&": flush(); tokens.append(.and)
            case "|": flush(); tokens.append(.or)
            case "!": flush(); tokens.append(.not)
            case "(": flush(); tokens.append(.lparen)
            case ")": flush(); tokens.append(.rparen)
            case let c where c.isWhitespace: flush()
            default: current.append(ch)
            }
        }
        flush()
        return tokens
    }

    // MARK: - Recursive-descent parser
    //
    //   orExpr  := andExpr ( '|' andExpr )*
    //   andExpr := notExpr ( '&'? notExpr )*      // juxtaposition == implicit AND
    //   notExpr := '!' notExpr | primary
    //   primary := '(' orExpr ')' | term
    //
    // Each parse method consumes at least one token whenever it recurses inside a loop, so the
    // parser always terminates even on malformed input.

    private struct Parser {
        let tokens: [Token]
        var pos = 0

        var peek: Token? { pos < tokens.count ? tokens[pos] : nil }

        mutating func parseOr() -> Node {
            var left = parseAnd()
            while peek == .or {
                pos += 1
                left = .or(left, parseAnd())
            }
            return left
        }

        mutating func parseAnd() -> Node {
            var left = parseNot()
            while true {
                if peek == .and {
                    pos += 1
                    left = .and(left, parseNot())
                } else if startsFactor(peek) {
                    left = .and(left, parseNot())   // adjacency == implicit AND
                } else {
                    return left
                }
            }
        }

        mutating func parseNot() -> Node {
            if peek == .not {
                pos += 1
                let operand = parseNot()
                // A '!' with no real operand (trailing '!', "bug!") is ignored rather than
                // flipped into "match nothing".
                if case .all = operand { return .all }
                return .not(operand)
            }
            return parsePrimary()
        }

        mutating func parsePrimary() -> Node {
            switch peek {
            case .lparen:
                pos += 1
                let inner = parseOr()
                if peek == .rparen { pos += 1 }     // tolerate a missing ')'
                return inner
            case .term(let t):
                pos += 1
                return .term(t)
            default:
                // Stray operator, a leading ')' , or end-of-input: consume one token (if any) to
                // guarantee forward progress and treat it as a match-everything fragment.
                if pos < tokens.count { pos += 1 }
                return .all
            }
        }

        func startsFactor(_ token: Token?) -> Bool {
            switch token {
            case .term, .not, .lparen: return true
            default: return false
            }
        }
    }
}
