import Type_Algebra_Syntax
import SwiftCompilerPlugin
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

struct StoredProperty {
    let name: String
    let type: TypeSyntax
    let defaultValue: ExprSyntax?
    let accessLevel: String?
    let isVar: Bool
}

public struct CoWMacro {}

extension CoWMacro: MemberMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {

        guard let structDecl = declaration.as(StructDeclSyntax.self) else {
            throw CoWMacroError.onlyApplicableToStruct
        }

        let properties = try extractStoredProperties(from: structDecl)

        guard !properties.isEmpty else {
            throw CoWMacroError.noStoredProperties
        }

        let varProperties = properties.filter { $0.isVar }

        guard !varProperties.isEmpty else {
            throw CoWMacroError.noVarProperties
        }

        let inheritedTypeNames =
            structDecl.inheritanceClause?.inheritedTypes.map {
                $0.type.trimmedDescription
            } ?? []
        let wantsSendable = inheritedTypeNames.contains("Sendable")

        if wantsSendable {
            for property in varProperties where containsFunctionType(property.type) {
                context.diagnose(
                    Diagnostic(
                        node: property.type,
                        message: CoWMacroDiagnostic.uncheckedSendableFunctionProperty(
                            propertyName: property.name
                        )
                    )
                )
            }
        }

        let storageClass = generateStorageClass(
            properties: varProperties,
            isSendable: wantsSendable
        )

        let storageProperty: DeclSyntax = "private var storage: Storage"

        let ensureUniqueAccess = "private"
        let ensureUnique: DeclSyntax = """
            \(raw: ensureUniqueAccess) mutating func ensureUnique() {
                if !isKnownUniquelyReferenced(&storage) {
                    storage = Storage(copying: storage)
                }
            }
            """

        let initializer = generateInitializer(
            properties: properties,
            structAccessLevel: extractAccessLevel(from: structDecl.modifiers)
        )

        let structName = structDecl.name.text
        let structAccessLevel = extractAccessLevel(from: structDecl.modifiers)
        let isIdenticalAccess = structAccessLevel.map { "\($0) " } ?? ""
        let isIdentical: DeclSyntax = """
            \(raw: isIdenticalAccess)func isIdentical(to other: \(raw: structName)) -> Bool {
                storage === other.storage
            }
            """

        return [
            storageClass,
            storageProperty,
            ensureUnique,
            initializer,
            isIdentical,
        ]
    }
}

extension CoWMacro: MemberAttributeMacro {
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingAttributesFor member: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AttributeSyntax] {

        guard let varDecl = member.as(VariableDeclSyntax.self) else {
            return []
        }

        guard !isComputedProperty(varDecl) else {
            return []
        }

        guard !varDecl.modifiers.contains(where: { $0.name.tokenKind == .keyword(.static) }) else {
            return []
        }

        for binding in varDecl.bindings {
            if let identifier = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text {
                if identifier == "storage" {
                    return []
                }
            }
        }

        guard varDecl.bindingSpecifier.tokenKind == .keyword(.var) else {
            return []
        }

        return [
            AttributeSyntax(attributeName: IdentifierTypeSyntax(name: .identifier("_CoWProperty")))
        ]
    }
}

public struct CoWPropertyMacro {}

extension CoWPropertyMacro: AccessorMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingAccessorsOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AccessorDeclSyntax] {
        guard let varDecl = declaration.as(VariableDeclSyntax.self),
            let binding = varDecl.bindings.first,
            let identifier = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
        else {
            return []
        }

        let isLet = varDecl.bindingSpecifier.tokenKind == .keyword(.let)

        if isLet {

            return [
                """
                _read {
                    yield storage.\(raw: identifier)
                }
                """
            ]
        } else {

            return [
                """
                _read {
                    yield storage.\(raw: identifier)
                }
                """,
                """
                _modify {
                    ensureUnique()
                    yield &storage.\(raw: identifier)
                }
                """,
            ]
        }
    }
}

private func extractStoredProperties(from structDecl: StructDeclSyntax) throws -> [StoredProperty] {
    let analysis = StoredProperties(structDecl)
    guard analysis.diagnostics.isEmpty else {
        throw MacroExpansionErrorMessage("@CoW " + analysis.diagnostics.joined(separator: "; "))
    }
    guard !analysis.hasCustomInitializer else {
        throw MacroExpansionErrorMessage("@CoW owns initialization of its backing storage; custom initializers are not supported.")
    }
    let reserved: Set<String> = ["Storage", "storage", "ensureUnique", "isIdentical"]
    guard analysis.fields.allSatisfy({ !reserved.contains($0.name) }) else {
        throw MacroExpansionErrorMessage("@CoW stored properties collide with its generated storage members.")
    }
    return analysis.fields.map { field in
        StoredProperty(name: field.name, type: field.type, defaultValue: field.defaultValue,
            accessLevel: extractAccessLevel(from: field.declaration.modifiers), isVar: field.isMutable)
    }
}

private func isComputedProperty(_ varDecl: VariableDeclSyntax) -> Bool {
    for binding in varDecl.bindings {
        if let accessor = binding.accessorBlock {
            switch accessor.accessors {
            case .getter:
                return true

            case .accessors(let accessorList):
                for accessor in accessorList {
                    if accessor.accessorSpecifier.tokenKind == .keyword(.get)
                        || accessor.accessorSpecifier.tokenKind == .keyword(.set)
                    {
                        return true
                    }
                }
            }
        }
    }
    return false
}

private func extractAccessLevel(from modifiers: DeclModifierListSyntax) -> String? {
    for modifier in modifiers {
        switch modifier.name.tokenKind {
        case .keyword(.public): return "public"
        case .keyword(.private): return "fileprivate"
        case .keyword(.fileprivate): return "fileprivate"
        case .keyword(.internal): return "internal"
        case .keyword(.package): return "package"
        default: continue
        }
    }
    return nil
}

private func isOptionalType(_ type: TypeSyntax) -> Bool {

    if type.is(OptionalTypeSyntax.self) {
        return true
    }

    if type.is(ImplicitlyUnwrappedOptionalTypeSyntax.self) {
        return true
    }

    if let identifier = type.as(IdentifierTypeSyntax.self),
        identifier.name.text == "Optional"
    {
        return true
    }
    return false
}

private func containsFunctionType(_ type: TypeSyntax) -> Bool {
    if type.is(FunctionTypeSyntax.self) {
        return true
    }
    if let optional = type.as(OptionalTypeSyntax.self) {
        return containsFunctionType(optional.wrappedType)
    }
    if let iuo = type.as(ImplicitlyUnwrappedOptionalTypeSyntax.self) {
        return containsFunctionType(iuo.wrappedType)
    }
    if let attributed = type.as(AttributedTypeSyntax.self) {
        return containsFunctionType(attributed.baseType)
    }
    if let tuple = type.as(TupleTypeSyntax.self), tuple.elements.count == 1 {
        return containsFunctionType(tuple.elements[tuple.elements.startIndex].type)
    }
    return false
}

private func cleanTypeString(_ type: TypeSyntax) -> String {

    var result = ""
    var previousToken: String = ""

    for token in type.tokens(viewMode: .sourceAccurate) {
        let text = token.text

        guard !text.isEmpty else { continue }

        if !result.isEmpty && needsSpaceBetween(previousToken, text) {
            result += " "
        }

        result += text
        previousToken = text
    }

    return result
}

private func needsSpaceBetween(_ prev: String, _ next: String) -> Bool {

    if prev == "(" || prev == "[" || prev == "<" { return false }

    if next == ")" || next == "]" || next == ">" { return false }

    if prev == "." || next == "." { return false }

    if next == "," { return false }
    if prev == "," { return true }

    if next == ":" { return false }
    if prev == ":" { return true }

    if next == "?" || prev == "?" { return false }

    if next == "!" || prev == "!" { return false }

    if prev == "&" || next == "&" { return true }

    if prev == "->" || next == "->" { return true }

    if prev == "some" || prev == "any" || prev == "inout" || prev == "repeat" || prev == "each"
        || prev == "throws" || prev == "async" || prev == "rethrows"
    {
        return true
    }

    return false
}

private func cleanExprString(_ expr: ExprSyntax) -> String {
    var result = expr.trimmedDescription

    while result.contains("  ") {
        result = result.replacing("  ", with: " ")
    }
    return result
}

private func generateStorageClass(properties: [StoredProperty], isSendable: Bool) -> DeclSyntax {

    let storageProperties = properties.map { prop -> String in
        "var \(prop.name): \(cleanTypeString(prop.type))"
    }.joined(separator: "\n        ")

    let sendableConformance = isSendable ? ": @unchecked Sendable" : ""

    let initParams = properties.map { prop -> String in
        let typeStr = cleanTypeString(prop.type)
        if let defaultValue = prop.defaultValue {
            return "\(prop.name): \(typeStr) = \(cleanExprString(defaultValue))"
        } else if isOptionalType(prop.type) {
            return "\(prop.name): \(typeStr) = nil"
        } else {
            return "\(prop.name): \(typeStr)"
        }
    }.joined(separator: ", ")

    let initAssignments = properties.map { prop -> String in
        "self.\(prop.name) = \(prop.name)"
    }.joined(separator: "\n            ")

    let copyAssignments = properties.map { prop -> String in
        "self.\(prop.name) = other.\(prop.name)"
    }.joined(separator: "\n            ")

    return """
        // MARK: - CoW Generated Storage
        private final class Storage\(raw: sendableConformance) {
            \(raw: storageProperties)

            init(\(raw: initParams)) {
                \(raw: initAssignments)
            }

            init(copying other: Storage) {
                \(raw: copyAssignments)
            }
        }
        """
}

private func generateInitializer(
    properties: [StoredProperty],
    structAccessLevel: String?
) -> DeclSyntax {

    let accessModifier = structAccessLevel.map { "\($0) " } ?? ""

    let initialized = properties.filter { $0.isVar || $0.defaultValue == nil }
    let initParams = initialized.map { prop -> String in
        let typeStr = cleanTypeString(prop.type)
        if let defaultValue = prop.defaultValue {
            return "\(prop.name): \(typeStr) = \(cleanExprString(defaultValue))"
        } else if isOptionalType(prop.type) {
            return "\(prop.name): \(typeStr) = nil"
        } else {
            return "\(prop.name): \(typeStr)"
        }
    }.joined(separator: ", ")

    let storageArgs = properties.filter(\.isVar).map { prop -> String in
        "\(prop.name): \(prop.name)"
    }.joined(separator: ", ")

    let constants = initialized.filter { !$0.isVar }.map { "self.\($0.name) = \($0.name)" }.joined(separator: "\n")
    return """
        \(raw: accessModifier)init(\(raw: initParams)) {
            self.storage = Storage(\(raw: storageArgs))
            \(raw: constants)
        }
        """
}

enum CoWMacroError: Swift.Error, CustomStringConvertible {
    case onlyApplicableToStruct
    case noStoredProperties
    case noVarProperties
    case syntaxGenerationFailed(String)
}

extension CoWMacroError {
    var description: String {
        switch self {
        case .onlyApplicableToStruct:
            return
                "@CoW can only be applied to structs. Classes, enums, and actors are not supported."

        case .noStoredProperties:
            return
                "@CoW requires at least one stored property. Add a 'var' property to your struct."

        case .noVarProperties:
            return
                "@CoW requires at least one 'var' property. Change 'let' to 'var' or use 'private(set) var' for read-only properties."

        case .syntaxGenerationFailed(let detail):
            return
                "@CoW failed to build generated syntax internally (\(detail)). This indicates a bug in the macro implementation."
        }
    }
}

struct CoWMacroDiagnostic: DiagnosticMessage {
    private let propertyName: String

    static func uncheckedSendableFunctionProperty(propertyName: String) -> CoWMacroDiagnostic {
        CoWMacroDiagnostic(propertyName: propertyName)
    }

    var message: String {
        "Generated Storage is '@unchecked Sendable' because this struct declares 'Sendable', "
            + "but property '\(propertyName)' has a function type. Closures are not verified "
            + "Sendable-safe by the compiler — confirm captured state is safe to share across "
            + "isolation domains, or remove the 'Sendable' conformance."
    }

    var diagnosticID: MessageID {
        MessageID(domain: "CoWMacro", id: "uncheckedSendableFunctionProperty")
    }

    var severity: DiagnosticSeverity { .warning }
}
