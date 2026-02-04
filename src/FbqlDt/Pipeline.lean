-- SPDX-License-Identifier: PMPL-1.0-or-later
-- SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (@hyperpolymath)
--
-- Complete Parsing Pipeline: Source → IR
-- Orchestrates lexer, parser, type checker, IR generation

import FbqlDt.Lexer
import FbqlDt.Parser
import FbqlDt.TypeChecker
import FbqlDt.TypeInference
import FbqlDt.IR
import FbqlDt.Serialization

namespace FbqlDt.Pipeline

-- Mark entire namespace as noncomputable due to axiomatized parser functions
noncomputable section

open Lexer Parser TypeChecker TypeInference IR Serialization AST

/-!
# FBQLdt/FBQL Complete Parsing Pipeline

Provides end-to-end processing from source text to executable IR.

**Pipeline Stages:**

```
Source Text (FBQL or FBQLdt)
    ↓ 1. Lexer
Tokens
    ↓ 2. Parser
Typed AST (with or without explicit types)
    ↓ 3. Type Checker
Validated AST (proofs verified)
    ↓ 4. IR Generation
Typed IR (with proof blobs, permissions)
    ↓ 5. Serialization (optional)
CBOR bytes / JSON
    ↓ 6. Execution
FormDB Native or SQL Backend
```

**Two Modes:**
- **FBQLdt**: Explicit types + proofs → Compile-time verification
- **FBQL**: Type inference + auto-proofs → Runtime validation fallback
-/

-- ============================================================================
-- Pipeline Configuration
-- ============================================================================

/-- Parsing mode -/
inductive ParsingMode where
  | fbqld : ParsingMode   -- Explicit types, compile-time proofs
  | fbql : ParsingMode    -- Type inference, runtime validation
  deriving Repr, BEq

/-- Pipeline configuration -/
structure PipelineConfig where
  mode : ParsingMode
  schema : Schema
  permissions : PermissionMetadata
  validationLevel : ValidationLevel
  serializationFormat : SerializationFormat
  deriving Repr

/-- Default configuration for FBQL (user tier) -/
def defaultFBQLConfig (userId roleId : String) : PipelineConfig := {
  mode := .fbql,
  schema := evidenceSchema,  -- TODO: Schema registry lookup
  permissions := {
    userId := userId,
    roleId := roleId,
    validationLevel := .runtime,
    allowedTypes := [],  -- Empty = all types allowed
    timestamp := 0  -- TODO: Get current timestamp
  },
  validationLevel := .runtime,
  serializationFormat := .cbor
}

/-- Default configuration for FBQLdt (admin tier) -/
def defaultFBQLdtConfig (userId roleId : String) : PipelineConfig := {
  mode := .fbqld,
  schema := evidenceSchema,
  permissions := {
    userId := userId,
    roleId := roleId,
    validationLevel := .compile,
    allowedTypes := [],  -- Admin: all types allowed
    timestamp := 0
  },
  validationLevel := .compile,
  serializationFormat := .cbor
}

-- ============================================================================
-- Pipeline Stages
-- ============================================================================

/-- Stage 1: Tokenize source -/
def tokenizeSource (source : String) : Except String (List Token) :=
  tokenize source

/-- Stage 2: Parse tokens to AST -/
noncomputable def parseTokens (tokens : List Token) (config : PipelineConfig) : Except String (List Statement) := do
  let initialState : ParserState := {
    tokens := tokens,
    position := 0
  }

  match parseStatement initialState with
  | .ok stmt _ => .ok [stmt]
  | .error msg _ => .error msg

/-- Stage 3: Type check AST -/
def typeCheckAST (stmt : Statement) (config : PipelineConfig) : Except String Statement :=
  -- For FBQL, type inference already happened in parser
  -- For FBQLdt, verify explicit types and proofs
  match config.mode with
  | .fbql => .ok stmt  -- Type inference done, runtime validation will catch errors
  | .fbqld =>
      -- TODO: Verify proofs
      .ok stmt

/-- Stage 4: Generate IR from AST -/
def generateIRFromAST (stmt : Statement) (config : PipelineConfig) : Except String IR := do
  match stmt with
  | .insertFBQL inferred =>
      -- TODO: Convert InferredInsert to IR.Insert (needs schema lookup)
      .error "InferredInsert → IR conversion not yet implemented"
  | .insertFBQLdt inferred =>
      -- TODO: Convert InferredInsert to IR.Insert (needs schema lookup)
      .error "InferredInsert → IR conversion not yet implemented"
  | .select selectStmt =>
      .ok (generateIR_Select selectStmt config.permissions)
  | .update updateStmt =>
      -- TODO: Generate IR.Update (needs schema lookup)
      .error "UPDATE → IR conversion not yet implemented"
  | .delete deleteStmt =>
      -- TODO: Generate IR.Delete (needs schema lookup)
      .error "DELETE → IR conversion not yet implemented"

/-- Stage 5: Validate permissions -/
def validateIRPermissions (ir : IR) (config : PipelineConfig) : Except String Unit :=
  validatePermissions ir

/-- Stage 6: Serialize IR -/
noncomputable def serializeIRToBytes (ir : IR) (config : PipelineConfig) : ByteArray :=
  serializeIR ir  -- TODO: Use config.serializationFormat

-- ============================================================================
-- Complete Pipeline
-- ============================================================================

/-- Run complete pipeline: Source → IR -/
noncomputable def runPipeline (source : String) (config : PipelineConfig) : Except String IR := do
  -- Stage 1: Tokenize
  let tokens ← tokenizeSource source

  -- Stage 2: Parse
  let stmts ← parseTokens tokens config

  -- Get first statement (TODO: Handle multiple statements)
  let stmt ← match stmts.head? with
    | some s => .ok s
    | none => .error "No statements parsed"

  -- Stage 3: Type check
  let checkedStmt ← typeCheckAST stmt config

  -- Stage 4: Generate IR
  let ir ← generateIRFromAST checkedStmt config

  -- Stage 5: Validate permissions
  validateIRPermissions ir config

  -- Return validated IR
  .ok ir

/-- Run pipeline and serialize to bytes -/
noncomputable def runPipelineAndSerialize (source : String) (config : PipelineConfig) : Except String ByteArray := do
  let ir ← runPipeline source config
  .ok (serializeIRToBytes ir config)

-- ============================================================================
-- Convenience Functions
-- ============================================================================

/-- Parse FBQL query (user tier) -/
noncomputable def parseFBQL (source : String) (userId roleId : String) : Except String IR :=
  runPipeline source (defaultFBQLConfig userId roleId)

/-- Parse FBQLdt query (admin tier) -/
noncomputable def parseFBQLdt (source : String) (userId roleId : String) : Except String IR :=
  runPipeline source (defaultFBQLdtConfig userId roleId)

/-- Parse and execute query -/
def parseAndExecute (source : String) (config : PipelineConfig) : IO (Except String Unit) := do
  match runPipeline source config with
  | .ok ir =>
      -- TODO: Execute IR on FormDB
      IO.println s!"✓ Parsed successfully: {describeIR ir}"
      .ok (.ok ())
  | .error msg =>
      IO.println s!"✗ Parse error: {msg}"
      .ok (.error msg)

-- ============================================================================
-- Error Reporting
-- ============================================================================

/-- Pipeline error with context -/
structure PipelineError where
  stage : String  -- Which stage failed
  message : String
  source : String  -- Original source (for error highlighting)
  line : Nat
  column : Nat
  deriving Repr

/-- Format error for display -/
def formatError (err : PipelineError) : String :=
  s!"{err.stage} error at line {err.line}, column {err.column}:\n{err.message}\n\nSource:\n{err.source}"

-- ============================================================================
-- Examples
-- ============================================================================

/-- Example: Parse FBQL INSERT -/
def exampleParseFBQL : Except String IR :=
  parseFBQL
    "INSERT INTO evidence (title, score) VALUES ('ONS Data', 95) RATIONALE 'Official statistics';"
    "user123" "journalist"

-- #eval! exampleParseFBQL

/-- Example: Parse FBQLdt INSERT -/
def exampleParseFBQLdt : Except String IR :=
  parseFBQLdt
    "INSERT INTO evidence (title : NonEmptyString, score : BoundedNat 0 100) VALUES ('ONS Data', 95) RATIONALE 'Official statistics';"
    "admin456" "admin"

-- #eval! exampleParseFBQLdt

/-- Example: Parse SELECT -/
def exampleParseSelect : Except String IR :=
  parseFBQL
    "SELECT * FROM evidence;"
    "user123" "journalist"

-- #eval! exampleParseSelect

/-- Example: Complete pipeline with serialization -/
noncomputable def examplePipelineWithSerialization : IO Unit := do
  let config := defaultFBQLConfig "user123" "journalist"

  match runPipelineAndSerialize
    "INSERT INTO evidence (title, score) VALUES ('ONS Data', 95) RATIONALE 'Official statistics';"
    config with
  | .ok bytes =>
      IO.println s!"✓ Parsed and serialized: {bytes.size} bytes (CBOR)"
  | .error msg =>
      IO.println s!"✗ Error: {msg}"

-- ============================================================================
-- Testing & Validation
-- ============================================================================

/-- Test: Valid FBQL query should parse -/
def testValidFBQL : IO Bool := do
  match parseFBQL "INSERT INTO evidence (title) VALUES ('Test') RATIONALE 'Test';" "test" "user" with
  | .ok _ =>
      IO.println "✓ Valid FBQL query parsed"
      return true
  | .error msg =>
      IO.println s!"✗ Valid FBQL query failed: {msg}"
      return false

/-- Test: Invalid query should error -/
def testInvalidQuery : IO Bool := do
  match parseFBQL "INVALID SYNTAX HERE" "test" "user" with
  | .ok _ =>
      IO.println "✗ Invalid query should not parse"
      return false
  | .error _ =>
      IO.println "✓ Invalid query correctly rejected"
      return true

/-- Run all tests -/
def runTests : IO Unit := do
  IO.println "=== FBQLdt Pipeline Tests ==="
  let _ ← testValidFBQL
  let _ ← testInvalidQuery
  IO.println "=== Tests Complete ==="

end -- noncomputable section

end FbqlDt.Pipeline
