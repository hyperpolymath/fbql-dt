-- SPDX-License-Identifier: PMPL-1.0-or-later
-- SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (@hyperpolymath)
--
-- Abstract Syntax Tree with Dependent Types
-- Type-safe representation of FBQLdt queries

import FbqlDt.Types
import FbqlDt.Types.BoundedNat
import FbqlDt.Types.NonEmptyString
import FbqlDt.Provenance
import FbqlDt.Prompt

namespace FbqlDt.AST

open Types Provenance Prompt

-- ============================================================================
-- Type Inference Support
-- ============================================================================

/-- Inferred type from literals (before type checking)

    Used by FBQL parser to represent values before schema lookup.
-/
inductive InferredType where
  | nat : Nat → InferredType
  | int : Int → InferredType
  | string : String → InferredType
  | bool : Bool → InferredType
  | float : Float → InferredType
  deriving Repr

-- ============================================================================
-- Core Type Definitions (Ordered by Dependencies)
-- ============================================================================

-- Type expressions (indexed by actual Lean 4 types)
-- NO DEPENDENCIES - Define first
inductive TypeExpr where
  | nat : TypeExpr
  | int : TypeExpr
  | string : TypeExpr
  | bool : TypeExpr
  | float : TypeExpr
  | uuid : TypeExpr
  | timestamp : TypeExpr
  -- Refinement types
  | boundedNat : (min max : Nat) → TypeExpr
  | boundedFloat : (min max : Float) → TypeExpr
  | nonEmptyString : TypeExpr
  | confidence : TypeExpr
  -- Dependent types
  | vector : TypeExpr → Nat → TypeExpr
  | tracked : TypeExpr → TypeExpr
  | promptScores : TypeExpr
  deriving Repr

-- Normal form levels
-- NO DEPENDENCIES
inductive NormalForm where
  | nf1 : NormalForm
  | nf2 : NormalForm
  | nf3 : NormalForm
  | bcnf : NormalForm
  | nf4 : NormalForm
  deriving Repr

-- Type-safe values indexed by their types
-- DEPENDS ON: TypeExpr
inductive TypedValue : TypeExpr → Type where
  | nat : Nat → TypedValue .nat
  | int : Int → TypedValue .int
  | string : String → TypedValue .string
  | bool : Bool → TypedValue .bool
  | float : Float → TypedValue .float
  | boundedNat : (min max : Nat) → BoundedNat min max → TypedValue (.boundedNat min max)
  | nonEmptyString : NonEmptyString → TypedValue .nonEmptyString
  | tracked : {α : TypeExpr} → Tracked (TypedValue α) → TypedValue (.tracked α)
  | promptScores : PromptScores → TypedValue .promptScores

-- Row: list of typed values
-- DEPENDS ON: TypeExpr, TypedValue
def Row := List (String × Σ t : TypeExpr, TypedValue t)

-- Constraints with proofs
-- DEPENDS ON: Row
inductive Constraint where
  | check : String → (row : Row) → Prop → Constraint
  | foreignKey : String → String → Constraint
  | unique : List String → Constraint

-- Column definition with type-level constraints
-- DEPENDS ON: TypeExpr
structure ColumnDef where
  name : String
  type : TypeExpr
  isPrimaryKey : Bool
  isUnique : Bool
  deriving Repr

-- Schema definition with dependent types
-- DEPENDS ON: ColumnDef, Constraint, NormalForm
structure Schema where
  name : String
  columns : List ColumnDef
  constraints : List Constraint
  normalForm : Option NormalForm
  deriving Repr

-- Type-safe INSERT statement
structure InsertStmt (schema : Schema) where
  table : String
  columns : List String
  values : List (Σ t : TypeExpr, TypedValue t)
  rationale : Rationale
  addedBy : Option ActorId
  -- Type safety proof: values match column types
  typesMatch : ∀ i, i < values.length →
    ∃ col ∈ schema.columns,
      col.name = columns.get! i ∧
      (values.get! i).1 = col.type
  -- Provenance proof: rationale is non-empty (automatic via Rationale type)
  deriving Repr

-- Type-safe SELECT statement with result type
structure SelectStmt (resultType : Type) where
  selectList : SelectList
  from : FromClause
  where_ : Option Condition
  returning : Option (TypeRefinement resultType)
  deriving Repr

inductive SelectList where
  | star : SelectList
  | columns : List String → SelectList
  | typed : (t : Type) → TypeRefinement t → SelectList
  deriving Repr

structure FromClause where
  tables : List TableRef
  deriving Repr

structure TableRef where
  name : String
  alias : Option String
  deriving Repr

-- Type refinement: filters results to those satisfying predicate
structure TypeRefinement (α : Type) where
  predicate : α → Prop
  proof : ∀ x : α, Decidable (predicate x)

-- Conditions with type checking
inductive Condition where
  | eq : {t : TypeExpr} → TypedValue t → TypedValue t → Condition
  | lt : {t : TypeExpr} → TypedValue t → TypedValue t → Condition
  | and : Condition → Condition → Condition
  | or : Condition → Condition → Condition
  | not : Condition → Condition
  deriving Repr

/-- WHERE clause with optional proof obligation

    Parser produces simplified (String × String × InferredType) representation
    which is later type-checked against schema to produce full Condition.
-/
structure WhereClause where
  predicate : (String × String × InferredType)  -- Simplified: (column, op, value)
  proof : Unit → True  -- Placeholder for proof obligation
  deriving Repr

/-- ORDER BY clause with column names and directions -/
structure OrderByClause where
  columns : List (String × String)  -- (column, direction: "ASC" or "DESC")
  deriving Repr

-- Type-safe UPDATE statement
structure UpdateStmt (schema : Schema) where
  table : String
  assignments : List Assignment
  where_ : Condition
  rationale : Rationale
  -- Type safety: assignments match column types
  typesMatch : ∀ a ∈ assignments,
    ∃ col ∈ schema.columns,
      col.name = a.column ∧
      a.value.1 = col.type
  deriving Repr

structure Assignment where
  column : String
  value : Σ t : TypeExpr, TypedValue t
  deriving Repr

-- Type-safe DELETE statement
structure DeleteStmt where
  table : String
  where_ : Condition
  rationale : Rationale
  deriving Repr

-- Proof obligations for INSERT
structure InsertProofObligation (stmt : InsertStmt schema) where
  -- All values satisfy their type constraints
  valuesValid : ∀ i, i < stmt.values.length →
    let ⟨t, v⟩ := stmt.values.get! i
    satisfiesConstraints v t
  -- Rationale is non-empty (automatically satisfied by Rationale type)
  -- Can be extended with custom proof obligations

-- Helper: check if value satisfies type constraints
def satisfiesConstraints {t : TypeExpr} (v : TypedValue t) (ty : TypeExpr) : Prop :=
  match t, ty with
  | .boundedNat min max, .boundedNat min' max' =>
      min = min' ∧ max = max' ∧
      match v with
      | .boundedNat _ _ bn => bn.val ≥ min ∧ bn.val ≤ max
      | _ => False
  | .nonEmptyString, .nonEmptyString =>
      match v with
      | .nonEmptyString nes => nes.val.length > 0
      | _ => False
  | _, _ => True  -- Other types checked structurally

end FbqlDt.AST
