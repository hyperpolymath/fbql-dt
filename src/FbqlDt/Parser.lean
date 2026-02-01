-- SPDX-License-Identifier: PMPL-1.0-or-later
-- SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (@hyperpolymath)
--
-- Parser for FBQLdt/FBQL
-- Parses tokens into typed AST

import FbqlDt.Lexer
import FbqlDt.AST
import FbqlDt.TypeInference
import FbqlDt.IR
import FbqlDt.Types
import FbqlDt.Types.NonEmptyString
import FbqlDt.Types.BoundedNat
import FbqlDt.Types.Confidence
import FbqlDt.Provenance

namespace FbqlDt.Parser

open Lexer AST TypeInference IR Types

/-!
# FBQLdt/FBQL Parser

Parses tokenized source into typed AST.

**Two parsing modes:**
1. **FBQLdt** - Explicit types, proofs required
2. **FBQL** - Type inference, runtime validation

**Architecture:**
```
Tokens (from Lexer)
    ↓
Parser Combinators
    ↓
Typed AST (with or without explicit types)
    ↓
Type Checker (verify proofs)
    ↓
Typed IR (ready for execution)
```
-/

-- ============================================================================
-- Parser State
-- ============================================================================

/-- Parser state: current position in token stream -/
structure ParserState where
  tokens : List Token
  position : Nat
  deriving Repr

/-- Parser result -/
inductive ParseResult (α : Type) where
  | ok : α → ParserState → ParseResult α
  | error : String → ParserState → ParseResult α
  deriving Repr

/-- Parser monad -/
def Parser (α : Type) := ParserState → ParseResult α

instance : Monad Parser where
  pure x := fun s => .ok x s
  bind p f := fun s =>
    match p s with
    | .ok x s' => f x s'
    | .error msg s' => .error msg s'

/-- Fail with error message -/
def fail {α : Type} (msg : String) : Parser α :=
  fun s => .error msg s

-- ============================================================================
-- Basic Parser Combinators
-- ============================================================================

/-- Get current token without consuming -/
def peek : Parser (Option Token) := fun s =>
  match s.tokens.get? s.position with
  | some tok => .ok (some tok) s
  | none => .ok none s

/-- Consume current token -/
def advance : Parser Unit := fun s =>
  .ok () { s with position := s.position + 1 }

/-- Get current token and consume -/
def next : Parser (Option Token) := fun s =>
  match s.tokens.get? s.position with
  | some tok => .ok (some tok) { s with position := s.position + 1 }
  | none => .ok none s

/-- Expect specific token type -/
def expect (tokType : TokenType) : Parser Token := fun s =>
  match s.tokens.get? s.position with
  | some tok =>
      if tok.type == tokType then
        .ok tok { s with position := s.position + 1 }
      else
        .error s!"Expected {tokType}, got {tok.type}" s
  | none =>
      .error s!"Expected {tokType}, got EOF" s

/-- Expect identifier and return its name -/
def expectIdentifier : Parser String := fun s =>
  match s.tokens.get? s.position with
  | some tok =>
      match tok.type with
      | .identifier name => .ok name { s with position := s.position + 1 }
      | _ => .error s!"Expected identifier, got {tok.type}" s
  | none => .error "Expected identifier, got EOF" s

/-- Parse optional element -/
def optional (p : Parser α) : Parser (Option α) := fun s =>
  match p s with
  | .ok x s' => .ok (some x) s'
  | .error _ _ => .ok none s

/-- Parse zero or more elements -/
partial def many (p : Parser α) : Parser (List α) := fun s =>
  match p s with
  | .ok x s' =>
      match many p s' with
      | .ok xs s'' => .ok (x :: xs) s''
      | .error _ _ => .ok [x] s'  -- Should not happen
  | .error _ _ => .ok [] s

/-- Parse one or more elements -/
def many1 (p : Parser α) : Parser (List α) := do
  let x ← p
  let xs ← many p
  return x :: xs

/-- Parse elements separated by delimiter -/
partial def sepBy (p : Parser α) (sep : Parser β) : Parser (List α) := fun s =>
  match p s with
  | .ok x s' =>
      match sep s' with
      | .ok _ s'' =>
          match sepBy p sep s'' with
          | .ok xs s''' => .ok (x :: xs) s'''
          | .error _ _ => .ok [x] s'
      | .error _ _ => .ok [x] s'
  | .error _ _ => .ok [] s

-- ============================================================================
-- Expression Parsing
-- ============================================================================

/-- Parse literal value -/
def parseLiteral : Parser InferredType := fun s =>
  match s.tokens.get? s.position with
  | some tok =>
      match tok.type with
      | .litNat n => .ok (.nat n) { s with position := s.position + 1 }
      | .litInt i => .ok (.int i) { s with position := s.position + 1 }
      | .litString str => .ok (.string str) { s with position := s.position + 1 }
      | .litBool b => .ok (.bool b) { s with position := s.position + 1 }
      | .litFloat f => .ok (.float f) { s with position := s.position + 1 }
      | _ => .error s!"Expected literal, got {tok.type}" s
  | none => .error "Expected literal, got EOF" s

-- ============================================================================
-- Type Expression Parsing
-- ============================================================================

/-- Parse type expression -/
def parseTypeExpr : Parser TypeExpr := fun s =>
  match s.tokens.get? s.position with
  | some tok =>
      match tok.type with
      | .kwNat => .ok .nat { s with position := s.position + 1 }
      | .kwInt => .ok .int { s with position := s.position + 1 }
      | .kwString => .ok .string { s with position := s.position + 1 }
      | .kwBool => .ok .bool { s with position := s.position + 1 }
      | .kwNonEmptyString => .ok .nonEmptyString { s with position := s.position + 1 }
      | .kwConfidence => .ok .confidence { s with position := s.position + 1 }

      | .kwBoundedNat =>
          -- BoundedNat min max
          let s1 := { s with position := s.position + 1 }
          match s1.tokens.get? s1.position with
          | some minTok =>
              match minTok.type with
              | .litNat min =>
                  let s2 := { s1 with position := s1.position + 1 }
                  match s2.tokens.get? s2.position with
                  | some maxTok =>
                      match maxTok.type with
                      | .litNat max =>
                          .ok (.boundedNat min max) { s2 with position := s2.position + 1 }
                      | _ => .error "Expected max value for BoundedNat" s2
                  | none => .error "Expected max value for BoundedNat" s2
              | _ => .error "Expected min value for BoundedNat" s1
          | none => .error "Expected min value for BoundedNat" s1

      | .kwPromptScores => .ok .promptScores { s with position := s.position + 1 }

      | _ => .error s!"Expected type expression, got {tok.type}" s
  | none => .error "Expected type expression, got EOF" s

-- ============================================================================
-- INSERT Parsing
-- ============================================================================

/-- Parse column list: (col1, col2, col3) -/
def parseColumnList : Parser (List String) := do
  expect .leftParen
  let cols ← sepBy expectIdentifier (expect .comma)
  expect .rightParen
  return cols

/-- Parse column with optional type annotation: name or name : Type -/
def parseColumnWithType : Parser (String × Option TypeExpr) := do
  let name ← expectIdentifier
  let typeAnnot ← optional (do
    expect .opDoubleColon
    parseTypeExpr)
  return (name, typeAnnot)

/-- Parse typed column list: (col1 : Type1, col2 : Type2) -/
def parseTypedColumnList : Parser (List (String × TypeExpr)) := do
  expect .leftParen
  let cols ← sepBy (do
    let name ← expectIdentifier
    expect .opDoubleColon
    let ty ← parseTypeExpr
    return (name, ty)) (expect .comma)
  expect .rightParen
  return cols

/-- Parse VALUES clause -/
def parseValues : Parser (List InferredType) := do
  expect .kwValues
  expect .leftParen
  let vals ← sepBy parseLiteral (expect .comma)
  expect .rightParen
  return vals

/-- Parse RATIONALE clause -/
def parseRationale : Parser String := do
  expect .kwRationale
  match ← next with
  | some tok =>
      match tok.type with
      | .litString s => return s
      | _ => fun s => .error "Expected string for RATIONALE" s
  | none => fun s => .error "Expected RATIONALE value" s

/-- Parse INSERT statement (FBQL - no types) -/
def parseInsertFBQL : Parser InferredInsert := do
  expect .kwInsert
  expect .kwInto
  let table ← expectIdentifier
  let columns ← parseColumnList
  let values ← parseValues
  let rationale ← parseRationale
  optional (expect .semicolon)

  -- Type inference happens here
  match inferInsert evidenceSchema table columns values rationale with
  | .ok inferred => return inferred
  | .error msg => throw msg

/-- Parse INSERT statement (FBQLdt - explicit types) -/
def parseInsertFBQLdt : Parser InferredInsert := do
  expect .kwInsert
  expect .kwInto
  let table ← expectIdentifier
  let typedColumns ← parseTypedColumnList
  let values ← parseValues
  let rationale ← parseRationale
  optional (expect .semicolon)

  -- Extract columns and types
  let columns := typedColumns.map (·.1)
  let expectedTypes := typedColumns.map (·.2)

  -- Type check values against expected types
  -- TODO: Verify values match expected types
  match inferInsert evidenceSchema table columns values rationale with
  | .ok inferred => return inferred
  | .error msg => throw msg

-- ============================================================================
-- SELECT Parsing
-- ============================================================================

/-- Parse SELECT list -/
def parseSelectList : Parser SelectList := do
  expect .kwSelect
  match ← peek with
  | some tok =>
      match tok.type with
      | .opStar =>
          advance
          return .star
      | _ =>
          let cols ← sepBy expectIdentifier (expect .comma)
          return .columns cols
  | none => fail "Expected SELECT list"

/-- Parse FROM clause -/
def parseFromClause : Parser FromClause := do
  expect .kwFrom
  let tables ← sepBy (do
    let name ← expectIdentifier
    let alias ← optional (do
      expect .kwAs
      expectIdentifier)
    return { name := name, alias := alias }) (expect .comma)
  return { tables := tables }

/-- Parse WHERE clause -/
def parseWhereClause : Parser WhereClause := do
  expect .kwWhere
  -- Parse simple predicate (column op value)
  let column ← expectIdentifier
  let op ← parseComparisonOp
  let value ← parseLiteral
  return {
    predicate := (column, op, value),  -- Simplified for now
    proof := fun _ => inferInstance
  }

/-- Parse comparison operator -/
def parseComparisonOp : Parser String := fun s =>
  match s.tokens.get? s.position with
  | some tok =>
      match tok.type with
      | .opEq => .ok "=" { s with position := s.position + 1 }
      | .opLt => .ok "<" { s with position := s.position + 1 }
      | .opGt => .ok ">" { s with position := s.position + 1 }
      | .opLe => .ok "<=" { s with position := s.position + 1 }
      | .opGe => .ok ">=" { s with position := s.position + 1 }
      | .opNeq => .ok "!=" { s with position := s.position + 1 }
      | _ => .error s!"Expected comparison operator, got {tok.type}" s
  | none => .error "Expected comparison operator, got EOF" s

/-- Parse ORDER BY clause -/
def parseOrderBy : Parser OrderByClause := do
  expect .kwOrder
  expect .kwBy
  let columns ← sepBy (do
    let col ← expectIdentifier
    let direction ← optional (do
      match ← peek with
      | some tok =>
          match tok.type with
          | _ => return "ASC"  -- TODO: Parse ASC/DESC keywords
      | none => return "ASC"
    )
    return (col, direction.getD "ASC")
  ) (expect .comma)
  return { columns := columns }

/-- Parse LIMIT clause -/
def parseLimit : Parser Nat := do
  expect .kwLimit
  match ← next with
  | some tok =>
      match tok.type with
      | .litNat n => return n
      | _ => fail "Expected number for LIMIT"
  | none => fail "Expected LIMIT value"

/-- Parse SELECT statement -/
def parseSelect : Parser (SelectStmt Unit) := do
  let selectList ← parseSelectList
  let from ← parseFromClause
  let where_ ← optional parseWhereClause
  let orderBy ← optional parseOrderBy
  let limit ← optional parseLimit
  optional (expect .semicolon)

  return {
    selectList := selectList,
    from := from,
    where_ := where_,
    returning := none
  }

-- ============================================================================
-- UPDATE Parsing
-- ============================================================================

/-- Parse UPDATE statement -/
def parseUpdate : Parser UpdateStmt := do
  expect .kwUpdate
  let table ← expectIdentifier
  expect .kwSet
  -- Parse assignments (column = value)
  let assignments ← sepBy (do
    let column ← expectIdentifier
    expect .opEq
    let value ← parseLiteral
    return (column, value)
  ) (expect .comma)
  let where_ ← optional parseWhereClause
  let rationale ← parseRationale
  optional (expect .semicolon)

  return {
    table := table,
    assignments := assignments.map fun (col, val) => {
      column := col,
      value := ⟨inferTypeFromLiteral val, typedValueFromLiteral val⟩
    },
    where_ := where_,
    rationale := NonEmptyString.mk rationale sorry
  }

/-- Helper: Infer TypeExpr from InferredType -/
private def inferTypeFromLiteral (lit : InferredType) : TypeExpr :=
  match lit with
  | .nat _ => .nat
  | .int _ => .int
  | .string _ => .string
  | .bool _ => .bool
  | .float _ => .float

/-- Helper: Create TypedValue from InferredType -/
private def typedValueFromLiteral (lit : InferredType) : TypedValue (inferTypeFromLiteral lit) :=
  match lit with
  | .nat n => .nat n
  | .int i => .int i
  | .string s => .string s
  | .bool b => .bool b
  | .float f => .float f

-- ============================================================================
-- DELETE Parsing
-- ============================================================================

/-- Parse DELETE statement -/
def parseDelete : Parser DeleteStmt := do
  expect .kwDelete
  expect .kwFrom
  let table ← expectIdentifier
  -- WHERE is MANDATORY for safety
  let where_ ← parseWhereClause
  let rationale ← parseRationale
  optional (expect .semicolon)

  return {
    table := table,
    where_ := where_,
    rationale := NonEmptyString.mk rationale sorry
  }

-- ============================================================================
-- Top-Level Statement Parsing
-- ============================================================================

/-- Parse any statement -/
def parseStatement : Parser Statement := do
  match ← peek with
  | some tok =>
      match tok.type with
      | .kwInsert => do
          -- Check if next tokens indicate FBQLdt or FBQL
          -- For now, try FBQL first
          let insert ← parseInsertFBQL
          return .insertFBQL insert
      | .kwSelect => do
          let select ← parseSelect
          return .select select
      | .kwUpdate => do
          let update ← parseUpdate
          return .update update
      | .kwDelete => do
          let delete ← parseDelete
          return .delete delete
      | _ => fail s!"Unexpected token: {tok.type}"
  | none => fail "Unexpected EOF"

/-- Statement type for parsing -/
inductive Statement where
  | insertFBQL : InferredInsert → Statement
  | insertFBQLdt : InferredInsert → Statement
  | select : SelectStmt Unit → Statement
  | update : UpdateStmt → Statement
  | delete : DeleteStmt → Statement
  deriving Repr

/-- UPDATE statement AST -/
structure UpdateStmt where
  table : String
  assignments : List Assignment
  where_ : Option WhereClause
  rationale : NonEmptyString
  deriving Repr

/-- DELETE statement AST -/
structure DeleteStmt where
  table : String
  where_ : WhereClause
  rationale : NonEmptyString
  deriving Repr

/-- Assignment in UPDATE (imported from AST) -/
/-- ORDER BY clause (imported from AST) -/

-- ============================================================================
-- Public API
-- ============================================================================

/-- Parse source string to statements -/
def parse (source : String) : Except String (List Statement) := do
  -- Tokenize
  let tokens ← tokenize source

  -- Parse
  let initialState : ParserState := {
    tokens := tokens,
    position := 0
  }

  match parseStatement initialState with
  | .ok stmt _ => .ok [stmt]
  | .error msg _ => .error msg

/-- Parse and generate IR -/
def parseToIR (source : String) (permissions : PermissionMetadata) : Except String IR := do
  let stmts ← parse source

  match stmts.head? with
  | some (.insertFBQL inferred) =>
      -- Convert InferredInsert to IR.Insert
      -- TODO: Complete this conversion (needs schema)
      .error "InferredInsert → IR conversion not yet implemented"

  | some (.select selectStmt) =>
      .ok (generateIR_Select selectStmt permissions)

  | some (.update updateStmt) =>
      -- TODO: Generate IR.Update (needs schema)
      .error "UPDATE → IR conversion not yet implemented"

  | some (.delete deleteStmt) =>
      -- TODO: Generate IR.Delete (needs schema)
      .error "DELETE → IR conversion not yet implemented"

  | _ => .error "No statement parsed"

-- ============================================================================
-- Examples
-- ============================================================================

/-- Example: Parse simple INSERT -/
def exampleParseInsert : Except String (List Statement) :=
  parse "INSERT INTO evidence (title, score) VALUES ('ONS Data', 95) RATIONALE 'Official statistics';"

#eval exampleParseInsert

/-- Example: Parse SELECT -/
def exampleParseSelect : Except String (List Statement) :=
  parse "SELECT * FROM evidence;"

#eval exampleParseSelect

end FbqlDt.Parser
