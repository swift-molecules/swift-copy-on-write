# swift-copy-on-write

Use this package when a struct is copied far more often than it is changed, and you want copies to share one heap allocation instead of duplicating every field. Attach `@CoW` to the struct. It is the same macro as the one spelled out in full as Copy on Write.

## Laws

- Only stored `var` properties move into the shared storage. A `let` property stays on the struct itself. Computed and static properties are left alone.
- Copies share storage until one of them is mutated. The first mutation of a shared copy copies all of the `var` properties into new storage for that copy only. Mutating a value whose storage nothing else shares copies nothing.
- Mutating a nested `@CoW` value in place, such as `outer.inner.value = 1`, goes straight through to the inner storage. It does not copy the inner value out and back.
- `isIdentical(to:)` compares storage identity, not contents. Two values built separately with the same fields are not identical, and a copy stops being identical to its source as soon as either is mutated.
- The macro writes the struct's only initializer, with the struct's own access level, or `fileprivate` for a `private` struct. It takes every `var` and every `let` without a default. A `var` with a default keeps it as the parameter's default, and an optional `var` without one defaults to nil.
- The struct must have at least one stored `var`, no initializer of its own, and no property named `Storage`, `storage`, `ensureUnique` or `isIdentical`. Anything else is a compile error.
- The storage is `Sendable` only when the struct declares `Sendable`, and then every `var` property's type must be `Sendable` or the struct doesn't compile.
- Swift can't synthesize `Equatable`, `Hashable` or `Codable` for the struct, because its stored state is the storage reference. Write them yourself over the properties.
