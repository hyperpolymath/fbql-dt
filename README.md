# FQLdt: Dependently-Typed FormDB Query Language

**Status**: Research Prototype
**License**: MPL-2.0

FQLdt extends [FormDB](https://github.com/hyperpolymath/formdb)'s query language with **dependent types**, enabling compile-time verification of database constraints, provenance tracking, and reversibility proofs.

> **Note**: FQL stands for "FormDB Query Language"—the native query interface for FormDB. It is not related to HTML forms or form builders.

## Relationship to FormDB

```
┌─────────────────────────────────────────────────────────────┐
│  FQL (Factor)                  │  FQLdt (Lean 4)            │
│  - Runtime constraint checks   │  - Compile-time proofs     │
│  - Dynamic, practical          │  - Static, verified        │
│  - "Just run it"               │  - "Prove it first"        │
└───────────────┬────────────────┴────────────────┬───────────┘
                │                                  │
                ▼                                  ▼
┌─────────────────────────────────────────────────────────────┐
│  Form.Bridge (Zig) - Bidirectional ABI                      │
│  - No C dependency                                          │
│  - callconv(.C) for FFI compatibility                       │
├─────────────────────────────────────────────────────────────┤
│  Form.Model + Form.Blocks (Forth)                           │
│  - Single source of truth                                   │
└─────────────────────────────────────────────────────────────┘
```

**Same database, different guarantees:**

| Aspect | FQL (practical) | FQLdt (verified) |
|--------|-----------------|------------------|
| When constraints checked | Runtime | Compile-time |
| Invalid insert | Runtime error | Won't compile |
| Reversibility | Runtime inverse stored | Proof that inverse exists |
| PROMPT scores | `CHECK (score BETWEEN 0 AND 100)` | `BoundedNat 0 100` in type |
| Provenance | Application enforces | Type system enforces |

## Features

- **Refinement Types**: `BoundedNat 0 100`, `NonEmptyString`, `Confidence`
- **Dependent Types**: Length-indexed vectors, provenance-tracked values
- **Proof Obligations**: Compile-time verification of constraints
- **Reversibility Proofs**: Prove operations have inverses before execution
- **Normalization Types**: Type-encoded functional dependencies, normal form predicates (1NF-BCNF), proof-carrying schema evolution
- **Backward Compatible**: Standard FQL is valid in dependent-type mode

## Zig FFI (Bidirectional)

FQLdt compiles to operations on Form.Bridge, which uses Zig's stable ABI:

```zig
/// Bidirectional FFI: Lean 4 → Zig → Forth core
/// and Forth core → Zig → Lean 4 callbacks

pub const FdbStatus = struct {
    code: i32,
    error_blob: ?[*]const u8,
    error_len: usize,
};

/// Forward: FQLdt → Form.Bridge
pub export fn fdb_insert(
    db: *FdbDb,
    collection: [*:0]const u8,
    document: [*]const u8,
    doc_len: usize,
    proof_blob: [*]const u8,  // Serialised proof from Lean 4
    proof_len: usize,
) callconv(.C) FdbStatus;

/// Reverse: Form.Bridge → FQLdt (for constraint checking)
pub export fn fdb_register_constraint_checker(
    db: *FdbDb,
    checker: *const fn (doc: [*]const u8, len: usize) callconv(.C) bool,
) callconv(.C) FdbStatus;
```

No C headers or libc required. Zig provides C-compatible calling convention for interop.

## Specification

See [spec/FQL_Dependent_Types_Complete_Specification.md](spec/FQL_Dependent_Types_Complete_Specification.md) for the full specification covering:

1. Type System (universes, primitives, constructors)
2. Refinement Types (bounded values, non-empty strings)
3. Dependent Types (provenance tracking, reversibility)
4. DDL/DML with proofs
5. Proof obligations and tactics
6. Complete examples (BoFIG journalism use case)

See [spec/normalization-types.md](spec/normalization-types.md) for normalization types covering:

1. Functional dependency encoding (FunDep, Armstrong's Axioms)
2. Normal form predicates (1NF, 2NF, 3NF, BCNF, 4NF)
3. Proof-carrying schema evolution (NormalizationStep)
4. Integration with Form.Normalizer
5. FQL syntax extensions for normalization commands

## Setup

1. Ensure `just` and `podman` are installed
2. Run `just check` to verify Lean 4 proofs
3. For non-bash shells, see `scripts/bootstrap_all.sh`

## Implementation Timeline

- **Phase 1** (Month 1-6): Refinement types
- **Phase 2** (Month 7-12): Simple dependent types
- **Phase 3** (Month 13-18): Full verification
- **Phase 4** (Month 19-24): Normalization types (FunDep, normal forms, proof-carrying evolution)

## See Also

- [FormDB](https://github.com/hyperpolymath/formdb) - The narrative-first database
- [FormDB Self-Normalizing Spec](https://github.com/hyperpolymath/formdb/blob/main/spec/self-normalizing.adoc) - Self-normalizing database specification
- [FormDB Studio](https://github.com/hyperpolymath/formdb-studio) - Zero-friction GUI for FQLdt
- [BoFIG](https://github.com/hyperpolymath/bofig) - Evidence graph for investigative journalism
- [Zotero-FormDB](https://github.com/hyperpolymath/zotero-formdb) - Production pilot: reference manager with PROMPT scores
- [FormDB Debugger](https://github.com/hyperpolymath/formdb-debugger) - Proof-carrying database debugger (Lean 4 + Idris 2)
- [FormBase](https://github.com/hyperpolymath/formbase) - Open-source Airtable alternative with provenance
