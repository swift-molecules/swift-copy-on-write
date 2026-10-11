import Type_Algebra_Syntax
import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxMacros

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

        let varProperties = properties.filter { $0.isMutable }

        guard !varProperties.isEmpty else {
            throw CoWMacroError.noVarProperties
        }

        let wantsSendable = Type.Syntax.Conformance.contains("Sendable", in: structDecl)
        let storageClass = try generateStorageClass(
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

        let initializer = try generateInitializer(
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

        let read: AccessorDeclSyntax = """
            _read {
                yield storage.\(raw: identifier)
            }
            """
        guard varDecl.bindingSpecifier.tokenKind != .keyword(.let) else { return [read] }
        return [read, """
            _modify {
                ensureUnique()
                yield &storage.\(raw: identifier)
            }
            """]
    }
}

private func extractStoredProperties(from structDecl: StructDeclSyntax) throws -> [Type.Syntax.Properties.Field] {
    let analysis = Type.Syntax.Properties(structDecl)
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
    return analysis.fields
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

private func record(_ properties: [Type.Syntax.Properties.Field]) throws -> Type.Syntax.Record {
    try Type.Syntax.Record(properties.map { property in
        .init(property.name, type: property.type.trimmedDescription,
            initial: property.defaultValue?.trimmedDescription ?? (isOptionalType(property.type) ? "nil" : nil))
    })
}

private func generateStorageClass(properties: [Type.Syntax.Properties.Field], isSendable: Bool) throws -> DeclSyntax {

    let storageProperties = properties.map { prop -> String in
        "var \(prop.name): \(prop.type.trimmedDescription)"
    }.joined(separator: "\n        ")

    let sendableConformance = isSendable ? ": @unchecked Sendable" : ""

    let requirements = isSendable
        ? "func requireSendable<Value: Sendable>(_: Value.Type) {}\n" + properties.map { "requireSendable((\($0.type.trimmedDescription)).self)" }.joined(separator: "\n") : ""
    let initializer = try record(properties).initializer(access: "", prelude: requirements)

    let copyAssignments = properties.map { prop -> String in
        "self.\(prop.name) = other.\(prop.name)"
    }.joined(separator: "\n            ")

    return """
        // MARK: - CoW Generated Storage
        private final class Storage\(raw: sendableConformance) {
            \(raw: storageProperties)

            \(raw: initializer)

            init(copying other: Storage) {
                \(raw: copyAssignments)
            }
        }
        """
}

private func generateInitializer(
    properties: [Type.Syntax.Properties.Field],
    structAccessLevel: String?
) throws -> DeclSyntax {

    let accessModifier = structAccessLevel.map { "\($0) " } ?? ""

    let initialized = properties.filter { $0.isMutable || $0.defaultValue == nil }
    let parameters = try record(initialized).parameters
    let storage = try record(properties.filter(\.isMutable))
    let construction = try storage.constructing("Storage", from: .product(storage.fields.map { .value($0.binding) }))

    let constants = initialized.filter { !$0.isMutable }.map { "self.\($0.name) = \($0.name)" }.joined(separator: "\n")
    return """
        \(raw: accessModifier)init(\(raw: parameters)) {
            self.storage = \(raw: construction)
            \(raw: constants)
        }
        """
}

enum CoWMacroError: Swift::Error, CustomStringConvertible {
    case onlyApplicableToStruct
    case noStoredProperties
    case noVarProperties
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


        }
    }
}
