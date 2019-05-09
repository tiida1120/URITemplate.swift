import Foundation

// MARK: URITemplate

/// A data structure to represent an RFC6570 URI template.
public struct URITemplate: CustomStringConvertible, Equatable, Hashable, ExpressibleByStringLiteral {
    /// The underlying URI template
    public let template: String

    private var regex: NSRegularExpression {
        let expression: NSRegularExpression?
        do {
            expression = try NSRegularExpression(pattern: "\\{([^\\}]+)\\}")
        } catch {
            fatalError("Invalid Regex \(error)")
        }
        return expression!
    }

    private let operators: [Operator] = [
        StringExpansion(), ReservedExpansion(), FragmentExpansion(), LabelExpansion(), PathSegmentExpansion(),
        PathStyleParameterExpansion(), FormStyleQueryExpansion(), FormStyleQueryContinuation()
    ]

    /// Initialize a URITemplate with the given template
    public init(template: String) {
        self.template = template
    }

    public init(stringLiteral value: StringLiteralType) {
        self.template = value
    }

    public init(from decoder: Decoder) throws {
        self.template = try decoder.singleValueContainer().decode(String.self)
    }

    /// Returns a description of the URITemplate
    public var description: String {
        return template
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(template)
    }

    /// Returns the set of keywords in the URI Template
    public var variables: [String] {
        let expressions = regex.matches(template).map { expression -> String in
            // Removes the { and } from the expression
            String(expression.dropFirst().dropLast())
        }

        return expressions.map { expr -> [String] in
            var expression = expr

            for op in self.operators {
                if let op = op.op, expression.hasPrefix(op) {
                    expression = String(expression.dropFirst())
                    break
                }
            }

            return expression.components(separatedBy: ",").map { component in
                if component.hasSuffix("*") {
                    return String(component.dropLast())
                }
                return component
            }
        }.reduce([], +)
    }

    /// Expand template as a URI Template using the given variables
    public func expand(_ variables: [String: Any]) -> String {
        return regex.substitute(template) { string in
            var expression = String(string.dropFirst().dropLast())
            let firstCharacter = String(expression.first!)

            var op = self.operators.filter {
                if let op = $0.op {
                    return op == firstCharacter
                }

                return false
            }.first

            if op != nil {
                expression = String(expression.dropFirst())
            } else {
                op = self.operators.first
            }

            let rawExpansions = expression.components(separatedBy: ",").map { vari -> String? in
                var variable = vari
                var prefix: Int?

                if let range = variable.range(of: ":") {
                    prefix = Int(String(variable[range.upperBound...]))
                    variable = String(variable[..<range.lowerBound])
                }

                let explode = variable.hasSuffix("*")

                if explode {
                    variable = String(variable.dropLast())
                }

                if let value: Any = variables[variable] {
                    return op!.expand(variable, value: value, explode: explode, prefix: prefix)
                }

                return op!.expand(variable, value: nil, explode: false, prefix: prefix)
            }

            let expansions = rawExpansions.reduce([]) { (accumulator, expansion) -> [String] in
                if let expansion = expansion {
                    return accumulator + [expansion]
                }

                return accumulator
            }

            if !expansions.isEmpty {
                return op!.prefix + expansions.joined(separator: op!.joiner)
            }

            return ""
        }
    }

    func regexForVariable(_: String, op: Operator?) -> String {
        if op != nil {
            return "(.*)"
        } else {
            return "([A-z0-9%_\\-]+)"
        }
    }

    func regexForExpression(_ expression: String) -> String {
        var expression = expression

        let op = operators.filter {
            $0.op != nil && expression.hasPrefix($0.op!)
        }.first

        if op != nil {
            expression = String(expression.dropFirst())
        }

        let regexes = expression.components(separatedBy: ",").map { variable -> String in
            self.regexForVariable(variable, op: op)
        }

        return regexes.joined(separator: (op ?? StringExpansion()).joiner)
    }

    var extractionRegex: NSRegularExpression? {
        let regex = try! NSRegularExpression(pattern: "(\\{([^\\}]+)\\})|[^(.*)]")

        let pattern = regex.substitute(template) { expression in
            if expression.hasPrefix("{"), expression.hasSuffix("}") {
                let startIndex = expression.index(after: expression.startIndex)
                let endIndex = expression.index(before: expression.endIndex)
                return self.regexForExpression(String(expression[startIndex..<endIndex]))
            } else {
                return NSRegularExpression.escapedPattern(for: expression)
            }
        }

        do {
            return try NSRegularExpression(pattern: "^\(pattern)$")
        } catch _ {
            return nil
        }
    }

    /// Extract the variables used in a given URL
    public func extract(_ url: String) -> [String: String]? {
        if let expression = extractionRegex {
            let input = url as NSString
            let range = NSRange(location: 0, length: input.length)
            let results = expression.matches(in: url, range: range)

            if let result = results.first {
                var extractedVariables: [String: String] = [:]

                for (index, variable) in variables.enumerated() {
                    let range = result.range(at: index + 1)
                    let value = NSString(string: input.substring(with: range)).removingPercentEncoding
                    extractedVariables[variable] = value
                }

                return extractedVariables
            }
        }

        return nil
    }
}

extension URITemplate: Codable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(template)
    }
}

/// Determine if two URITemplate's are equivalent
public func == (lhs: URITemplate, rhs: URITemplate) -> Bool {
    return lhs.template == rhs.template
}

// MARK: Extensions

extension NSRegularExpression {
    func substitute(_ string: String, block: (String) -> (String)) -> String {
        let oldString = string as NSString
        let range = NSRange(location: 0, length: oldString.length)
        var newString = string as NSString

        let matches = self.matches(in: string, range: range)
        for match in Array(matches.reversed()) {
            let expression = oldString.substring(with: match.range)
            let replacement = block(expression)
            newString = newString.replacingCharacters(in: match.range, with: replacement) as NSString
        }

        return newString as String
    }

    func matches(_ string: String) -> [String] {
        let input = string as NSString
        let range = NSRange(location: 0, length: input.length)
        let results = matches(in: string, range: range)

        return results.map { result -> String in
            input.substring(with: result.range)
        }
    }
}

extension String {
    func percentEncoded() -> String {
        return addingPercentEncoding(withAllowedCharacters: CharacterSet.URITemplate.unreserved)!
    }
}

// MARK: Operators

protocol Operator {
    /// Operator
    var op: String? { get }

    /// Prefix for the expanded string
    var prefix: String { get }

    /// Character to use to join expanded components
    var joiner: String { get }

    func expand(_ variable: String, value: Any?, explode: Bool, prefix: Int?) -> String?
}

class BaseOperator {
    var joiner: String { return "," }

    func expand(_ variable: String, value: Any?, explode: Bool, prefix: Int?) -> String? {
        if let value = value {
            if let values = value as? [String: Any] {
                return expand(variable: variable, value: values, explode: explode)
            } else if let values = value as? [Any] {
                return expand(variable: variable, value: values, explode: explode)
            } else if let _ = value as? NSNull {
                return expand(variable: variable)
            } else {
                return expand(variable: variable, value: "\(value)", prefix: prefix)
            }
        }

        return expand(variable: variable)
    }

    // Point to overide to expand a value (i.e, perform encoding)
    func expand(value: String) -> String {
        return value
    }

    // Point to overide to expanding a string
    func expand(variable _: String, value: String, prefix: Int?) -> String {
        if let prefix = prefix {
            let valueCount = value.count
            if valueCount > prefix {
                let index = value.index(value.startIndex, offsetBy: prefix, limitedBy: value.endIndex)
                return expand(value: String(value[..<index!]))
            }
        }

        return expand(value: value)
    }

    // Point to overide to expanding an array
    func expand(variable _: String, value: [Any], explode: Bool) -> String? {
        let joiner = explode ? self.joiner : ","
        return value.map { self.expand(value: "\($0)") }.joined(separator: joiner)
    }

    // Point to overide to expanding a dictionary
    func expand(variable _: String, value: [String: Any], explode: Bool) -> String? {
        let joiner = explode ? self.joiner : ","
        let keyValueJoiner = explode ? "=" : ","
        let elements = value.map { (key, value) -> String in
            let expandedKey = self.expand(value: key)
            let expandedValue = self.expand(value: "\(value)")
            return "\(expandedKey)\(keyValueJoiner)\(expandedValue)"
        }

        return elements.joined(separator: joiner)
    }

    // Point to overide when value not found
    func expand(variable _: String) -> String? {
        return nil
    }
}

/// RFC6570 (3.2.2) Simple String Expansion: {var}
class StringExpansion: BaseOperator, Operator {
    var op: String? { return nil }
    var prefix: String { return "" }
    override var joiner: String { return "," }

    override func expand(value: String) -> String {
        return value.percentEncoded()
    }
}

/// RFC6570 (3.2.3) Reserved Expansion: {+var}
class ReservedExpansion: BaseOperator, Operator {
    var op: String? { return "+" }
    var prefix: String { return "" }
    override var joiner: String { return "," }

    override func expand(value: String) -> String {
        return value.addingPercentEncoding(withAllowedCharacters: CharacterSet.uriTemplateReservedAllowed)!
    }
}

/// RFC6570 (3.2.4) Fragment Expansion {#var}
class FragmentExpansion: BaseOperator, Operator {
    var op: String? { return "#" }
    var prefix: String { return "#" }
    override var joiner: String { return "," }

    override func expand(value: String) -> String {
        return value.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlFragmentAllowed)!
    }
}

/// RFC6570 (3.2.5) Label Expansion with Dot-Prefix: {.var}
class LabelExpansion: BaseOperator, Operator {
    var op: String? { return "." }
    var prefix: String { return "." }
    override var joiner: String { return "." }

    override func expand(value: String) -> String {
        return value.percentEncoded()
    }

    override func expand(variable: String, value: [Any], explode: Bool) -> String? {
        if !value.isEmpty {
            return super.expand(variable: variable, value: value, explode: explode)
        }

        return nil
    }
}

/// RFC6570 (3.2.6) Path Segment Expansion: {/var}
class PathSegmentExpansion: BaseOperator, Operator {
    var op: String? { return "/" }
    var prefix: String { return "/" }
    override var joiner: String { return "/" }

    override func expand(value: String) -> String {
        return value.percentEncoded()
    }

    override func expand(variable: String, value: [Any], explode: Bool) -> String? {
        if !value.isEmpty {
            return super.expand(variable: variable, value: value, explode: explode)
        }

        return nil
    }
}

/// RFC6570 (3.2.7) Path-Style Parameter Expansion: {;var}
class PathStyleParameterExpansion: BaseOperator, Operator {
    var op: String? { return ";" }
    var prefix: String { return ";" }
    override var joiner: String { return ";" }

    override func expand(value: String) -> String {
        return value.percentEncoded()
    }

    override func expand(variable: String, value: String, prefix: Int?) -> String {
        let valueCount = value.count
        if valueCount > 0 {
            let expandedValue = super.expand(variable: variable, value: value, prefix: prefix)
            return "\(variable)=\(expandedValue)"
        }

        return variable
    }

    override func expand(variable: String, value: [Any], explode: Bool) -> String? {
        let joiner = explode ? self.joiner : ","
        let expandedValue = value.map {
            let expandedValue = self.expand(value: "\($0)")

            if explode {
                return "\(variable)=\(expandedValue)"
            }

            return expandedValue
        }.joined(separator: joiner)

        if !explode {
            return "\(variable)=\(expandedValue)"
        }

        return expandedValue
    }

    override func expand(variable: String, value: [String: Any], explode: Bool) -> String? {
        let expandedValue = super.expand(variable: variable, value: value, explode: explode)

        if let expandedValue = expandedValue {
            if !explode {
                return "\(variable)=\(expandedValue)"
            }
        }

        return expandedValue
    }
}

/// RFC6570 (3.2.8) Form-Style Query Expansion: {?var}
class FormStyleQueryExpansion: BaseOperator, Operator {
    var op: String? { return "?" }
    var prefix: String { return "?" }
    override var joiner: String { return "&" }

    override func expand(value: String) -> String {
        return value.percentEncoded()
    }

    override func expand(variable: String, value: String, prefix: Int?) -> String {
        let expandedValue = super.expand(variable: variable, value: value, prefix: prefix)
        return "\(variable)=\(expandedValue)"
    }

    override func expand(variable: String, value: [Any], explode: Bool) -> String? {
        if !value.isEmpty {
            let joiner = explode ? self.joiner : ","
            let expandedValue = value.map {
                let expandedValue = self.expand(value: "\($0)")

                if explode {
                    return "\(variable)=\(expandedValue)"
                }

                return expandedValue
            }.joined(separator: joiner)

            if !explode {
                return "\(variable)=\(expandedValue)"
            }

            return expandedValue
        }

        return nil
    }

    override func expand(variable: String, value: [String: Any], explode: Bool) -> String? {
        if !value.isEmpty {
            let expandedVariable = expand(value: variable)
            let expandedValue = super.expand(variable: variable, value: value, explode: explode)

            if let expandedValue = expandedValue {
                if !explode {
                    return "\(expandedVariable)=\(expandedValue)"
                }
            }

            return expandedValue
        }

        return nil
    }
}

/// RFC6570 (3.2.9) Form-Style Query Continuation: {&var}
class FormStyleQueryContinuation: BaseOperator, Operator {
    var op: String? { return "&" }
    var prefix: String { return "&" }
    override var joiner: String { return "&" }

    override func expand(value: String) -> String {
        return value.percentEncoded()
    }

    override func expand(variable: String, value: String, prefix: Int?) -> String {
        let expandedValue = super.expand(variable: variable, value: value, prefix: prefix)
        return "\(variable)=\(expandedValue)"
    }

    override func expand(variable: String, value: [Any], explode: Bool) -> String? {
        let joiner = explode ? self.joiner : ","
        let expandedValue = value.map {
            let expandedValue = self.expand(value: "\($0)")

            if explode {
                return "\(variable)=\(expandedValue)"
            }

            return expandedValue
        }.joined(separator: joiner)

        if !explode {
            return "\(variable)=\(expandedValue)"
        }

        return expandedValue
    }

    override func expand(variable: String, value: [String: Any], explode: Bool) -> String? {
        let expandedValue = super.expand(variable: variable, value: value, explode: explode)

        if let expandedValue = expandedValue {
            if !explode {
                return "\(variable)=\(expandedValue)"
            }
        }

        return expandedValue
    }
}

private extension CharacterSet {
    struct URITemplate {
        static let digits = CharacterSet(charactersIn: "0"..."9")
        static let genDelims = CharacterSet(charactersIn: ":/?#[]@")
        static let subDelims = CharacterSet(charactersIn: "!$&'()*+,;=")
        static let unreservedSymbols = CharacterSet(charactersIn: "-._~")

        static let unreserved = {
            alpha.union(digits).union(unreservedSymbols)
        }()

        static let reserved = {
            genDelims.union(subDelims)
        }()

        static let alpha = { () -> CharacterSet in
            let upperAlpha = CharacterSet(charactersIn: "A"..."Z")
            let lowerAlpha = CharacterSet(charactersIn: "a"..."z")
            return upperAlpha.union(lowerAlpha)
        }()
    }

    static let uriTemplateReservedAllowed = {
        URITemplate.unreserved.union(URITemplate.reserved)
    }()
}
