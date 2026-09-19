@attached(
    member,
    names: named(Storage),
    named(storage),
    named(ensureUnique),
    named(init),
    named(isIdentical)
)
@attached(memberAttribute)
public macro `Copy on Write`() = #externalMacro(module: "Copy_on_Write_Macro_Plugin", type: "CoWMacro")

@attached(
    member,
    names: named(Storage),
    named(storage),
    named(ensureUnique),
    named(init),
    named(isIdentical)
)
@attached(memberAttribute)
public macro CoW() = #externalMacro(module: "Copy_on_Write_Macro_Plugin", type: "CoWMacro")

@attached(accessor, names: named(_read), named(_modify))
public macro _CoWProperty() =
    #externalMacro(module: "Copy_on_Write_Macro_Plugin", type: "CoWPropertyMacro")
