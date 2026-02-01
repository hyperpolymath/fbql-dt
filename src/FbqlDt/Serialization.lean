-- SPDX-License-Identifier: PMPL-1.0-or-later
-- SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (@hyperpolymath)
--
-- Serialization/Deserialization for FBQLdt Types
-- Converts between dependent types and storage formats (JSON, CBOR, binary)

import FbqlDt.Types
import FbqlDt.AST
import FbqlDt.Serialization.Types

namespace FbqlDt.Serialization

open Types AST Serialization.Types

/-!
# Serialization/Deserialization

Handles conversion between FBQLdt's dependent types and various storage formats:

1. **CBOR (Primary)** - Binary format for proof blobs, IR transport
2. **JSON** - For ReScript integration, web APIs, debugging
3. **Binary** - For high-performance FormDB storage
4. **Database-Native** - For SQL compatibility layer

**Design Principles:**
- Preserve type information in serialized form
- Include proofs in serialized representation
- Support round-trip (serialize → deserialize = identity)
- Versioned formats for schema evolution
-/

-- ============================================================================
-- JSON Serialization
-- ============================================================================

/-- Serialize TypedValue to JSON

    Format preserves type information:
    ```json
    {
      "type": "BoundedNat",
      "min": 0,
      "max": 100,
      "value": 95,
      "proof": "<base64-encoded-proof-blob>"
    }
    ```
-/
def serializeTypedValueJSON (tv : Σ t : TypeExpr, TypedValue t) : JsonValue :=
  match tv with
  | ⟨.nat, .nat n⟩ =>
      .object [
        ("type", .string "Nat"),
        ("value", .number n.toFloat)
      ]

  | ⟨.boundedNat min max, .boundedNat _ _ bn⟩ =>
      .object [
        ("type", .string "BoundedNat"),
        ("min", .number min.toFloat),
        ("max", .number max.toFloat),
        ("value", .number bn.val.toFloat),
        ("proof", .string "<base64-proof>")  -- TODO: Actual proof serialization
      ]

  | ⟨.nonEmptyString, .nonEmptyString nes⟩ =>
      .object [
        ("type", .string "NonEmptyString"),
        ("value", .string nes.val),
        ("proof", .string "<base64-proof>")
      ]

  | ⟨.confidence, .confidence c⟩ =>
      .object [
        ("type", .string "Confidence"),
        ("value", .number c.val.toFloat),
        ("proof", .string "<base64-proof>")
      ]

  | ⟨.promptScores, .promptScores scores⟩ =>
      .object [
        ("type", .string "PromptScores"),
        ("provenance", .number scores.provenance.val.toFloat),
        ("replicability", .number scores.replicability.val.toFloat),
        ("objective", .number scores.objective.val.toFloat),
        ("methodology", .number scores.methodology.val.toFloat),
        ("publication", .number scores.publication.val.toFloat),
        ("transparency", .number scores.transparency.val.toFloat),
        ("overall", .number scores.overall.val.toFloat),
        ("proof", .string "<base64-proof>")
      ]

  | _ => .null  -- TODO: Handle remaining types

/-- Deserialize TypedValue from JSON -/
def deserializeTypedValueJSON (json : JsonValue) : Except String (Σ t : TypeExpr, TypedValue t) :=
  match json with
  | .object fields =>
      -- Extract type tag
      let typeTag? := fields.find? (·.1 = "type")
      match typeTag? with
      | none => .error "Missing 'type' field in JSON"
      | some (_, .string "Nat") =>
          -- Extract value
          let value? := fields.find? (·.1 = "value")
          match value? with
          | some (_, .number n) => .ok ⟨.nat, .nat n.toUInt64.toNat⟩
          | _ => .error "Invalid 'value' for Nat"

      | some (_, .string "BoundedNat") =>
          -- Extract min, max, value
          let min? := fields.find? (·.1 = "min")
          let max? := fields.find? (·.1 = "max")
          let val? := fields.find? (·.1 = "value")
          match min?, max?, val? with
          | some (_, .number minF), some (_, .number maxF), some (_, .number valF) =>
              let min := minF.toUInt64.toNat
              let max := maxF.toUInt64.toNat
              let val := valF.toUInt64.toNat
              -- TODO: Verify proof from JSON
              if min ≤ val && val ≤ max then
                .ok ⟨.boundedNat min max, .boundedNat min max (BoundedNat.mk min max val sorry sorry)⟩
              else
                .error s!"Value {val} out of bounds [{min}, {max}]"
          | _, _, _ => .error "Invalid BoundedNat fields"

      | some (_, .string "NonEmptyString") =>
          let value? := fields.find? (·.1 = "value")
          match value? with
          | some (_, .string s) =>
              if s.length > 0 then
                .ok ⟨.nonEmptyString, .nonEmptyString (NonEmptyString.mk s sorry)⟩
              else
                .error "Empty string for NonEmptyString"
          | _ => .error "Invalid 'value' for NonEmptyString"

      | _ => .error "Unknown type tag"

  | _ => .error "Expected JSON object"

-- ============================================================================
-- CBOR Serialization (RFC 8949)
-- ============================================================================

-- CBOR types and tags imported from FbqlDt.Serialization.Types

/-- Serialize TypedValue to CBOR -/
def serializeTypedValueCBOR (tv : Σ t : TypeExpr, TypedValue t) : CBORValue :=
  match tv with
  | ⟨.nat, .nat n⟩ =>
      .unsigned n

  | ⟨.boundedNat min max, .boundedNat _ _ bn⟩ =>
      .tag cborTagBoundedNat (.map [
        (.textString "min", .unsigned min),
        (.textString "max", .unsigned max),
        (.textString "value", .unsigned bn.val),
        (.textString "proof", .byteString #[])  -- TODO: Actual proof
      ])

  | ⟨.nonEmptyString, .nonEmptyString nes⟩ =>
      .tag cborTagNonEmptyString (.map [
        (.textString "value", .textString nes.val),
        (.textString "proof", .byteString #[])
      ])

  | ⟨.confidence, .confidence c⟩ =>
      .tag cborTagConfidence (.map [
        (.textString "value", .unsigned c.val),
        (.textString "proof", .byteString #[])
      ])

  | ⟨.promptScores, .promptScores scores⟩ =>
      .tag cborTagPromptScores (.map [
        (.textString "provenance", .unsigned scores.provenance.val),
        (.textString "replicability", .unsigned scores.replicability.val),
        (.textString "objective", .unsigned scores.objective.val),
        (.textString "methodology", .unsigned scores.methodology.val),
        (.textString "publication", .unsigned scores.publication.val),
        (.textString "transparency", .unsigned scores.transparency.val),
        (.textString "overall", .unsigned scores.overall.val),
        (.textString "proof", .byteString #[])
      ])

  | _ => .simple 22  -- null

/-- Encode CBOR value to bytes -/
def encodeCBOR (value : CBORValue) : ByteArray :=
  match value with
  | .unsigned n =>
      if n < 24 then
        #[n.toUInt8]  -- Inline encoding (major type 0, value 0-23)
      else if n < 256 then
        #[24, n.toUInt8]  -- 1-byte encoding
      else if n < 65536 then
        let b1 := (n / 256).toUInt8
        let b2 := (n % 256).toUInt8
        #[25, b1, b2]  -- 2-byte encoding
      else if n < 4294967296 then
        let b1 := (n / 16777216).toUInt8
        let b2 := ((n / 65536) % 256).toUInt8
        let b3 := ((n / 256) % 256).toUInt8
        let b4 := (n % 256).toUInt8
        #[26, b1, b2, b3, b4]  -- 4-byte encoding
      else
        -- 8-byte encoding for very large numbers
        let u64 := n.toUInt64
        #[27] ++ u64.toLittleEndian

  | .negative i =>
      -- CBOR negative integers: major type 1, encoded as -1 - n
      let absVal := if i < 0 then (-i - 1).toNat else 0
      let header : UInt8 := 0x20  -- Major type 1
      if absVal < 24 then
        #[header + absVal.toUInt8]
      else if absVal < 256 then
        #[header + 24, absVal.toUInt8]
      else
        #[header + 25, (absVal / 256).toUInt8, (absVal % 256).toUInt8]

  | .byteString bytes =>
      let len := bytes.size
      let header : UInt8 := 0x40  -- Major type 2
      let headerBytes := if len < 24 then
        #[header + len.toUInt8]
      else if len < 256 then
        #[header + 24, len.toUInt8]
      else
        #[header + 25, (len / 256).toUInt8, (len % 256).toUInt8]
      headerBytes ++ bytes

  | .textString s =>
      let bytes := s.toUTF8
      let len := bytes.size
      let header : UInt8 := 0x60  -- Major type 3
      let headerBytes := if len < 24 then
        #[header + len.toUInt8]
      else if len < 256 then
        #[header + 24, len.toUInt8]
      else
        #[header + 25, (len / 256).toUInt8, (len % 256).toUInt8]
      headerBytes ++ bytes

  | .array items =>
      let len := items.length
      let header : UInt8 := 0x80  -- Major type 4
      let headerBytes := if len < 24 then
        #[header + len.toUInt8]
      else
        #[header + 24, len.toUInt8]
      items.foldl (fun acc item => acc ++ encodeCBOR item) headerBytes

  | .map pairs =>
      let len := pairs.length
      let header : UInt8 := 0xA0  -- Major type 5
      let headerBytes := if len < 24 then
        #[header + len.toUInt8]
      else
        #[header + 24, len.toUInt8]
      pairs.foldl (fun acc (k, v) =>
        acc ++ encodeCBOR k ++ encodeCBOR v
      ) headerBytes

  | .tag tag value =>
      let header : UInt8 := 0xC0  -- Major type 6
      let tagHeader := if tag < 24 then
        #[header + tag.toUInt8]
      else if tag < 256 then
        #[header + 24, tag.toUInt8]
      else
        #[header + 25, (tag / 256).toUInt8, (tag % 256).toUInt8]
      tagHeader ++ encodeCBOR value

  | .simple n =>
      -- Simple values: major type 7
      if n < 24 then
        #[0xE0 + n.toUInt8]
      else
        #[0xF8, n.toUInt8]

  | .float f =>
      -- IEEE 754 single-precision float (major type 7, additional info 26)
      -- For now, encode as double-precision
      #[0xFB] ++ f.toBits.toLittleEndian

/-- CBOR decoder state -/
structure CBORDecoder where
  bytes : ByteArray
  position : Nat
  deriving Repr

/-- Read one byte and advance position -/
def CBORDecoder.readByte (d : CBORDecoder) : Except String (UInt8 × CBORDecoder) :=
  if d.position >= d.bytes.size then
    .error "Unexpected end of CBOR data"
  else
    .ok (d.bytes.get! d.position, { d with position := d.position + 1 })

/-- Read N bytes and advance position -/
def CBORDecoder.readBytes (d : CBORDecoder) (n : Nat) : Except String (ByteArray × CBORDecoder) :=
  if d.position + n > d.bytes.size then
    .error "Unexpected end of CBOR data"
  else
    .ok (d.bytes.extract d.position (d.position + n), { d with position := d.position + n })

/-- Decode CBOR unsigned integer from additional info -/
def decodeUnsignedCBOR (d : CBORDecoder) (addInfo : UInt8) : Except String (Nat × CBORDecoder) :=
  if addInfo < 24 then
    -- Value encoded in additional info itself
    .ok (addInfo.toNat, d)
  else if addInfo == 24 then
    -- 1-byte follows
    do
      let (b, d') ← d.readByte
      .ok (b.toNat, d')
  else if addInfo == 25 then
    -- 2-byte follows (big-endian)
    do
      let (bytes, d') ← d.readBytes 2
      let val := bytes.get! 0 |>.toNat * 256 + bytes.get! 1 |>.toNat
      .ok (val, d')
  else if addInfo == 26 then
    -- 4-byte follows (big-endian)
    do
      let (bytes, d') ← d.readBytes 4
      let val := bytes.get! 0 |>.toNat * 16777216 +
                 bytes.get! 1 |>.toNat * 65536 +
                 bytes.get! 2 |>.toNat * 256 +
                 bytes.get! 3 |>.toNat
      .ok (val, d')
  else if addInfo == 27 then
    -- 8-byte follows (big-endian)
    do
      let (bytes, d') ← d.readBytes 8
      let val := UInt64.fromBigEndian bytes |>.toNat
      .ok (val, d')
  else
    .error s!"Invalid CBOR additional info: {addInfo}"

/-- Decode CBOR value recursively -/
partial def decodeCBORValue (d : CBORDecoder) : Except String (CBORValue × CBORDecoder) := do
  let (initByte, d1) ← d.readByte
  let majorType := initByte / 32  -- Top 3 bits
  let addInfo := initByte % 32    -- Bottom 5 bits

  match majorType with
  | 0 =>  -- Unsigned integer
      let (n, d2) ← decodeUnsignedCBOR d1 addInfo
      .ok (.unsigned n, d2)

  | 1 =>  -- Negative integer
      let (absVal, d2) ← decodeUnsignedCBOR d1 addInfo
      .ok (.negative (-(absVal.toInt + 1)), d2)

  | 2 =>  -- Byte string
      let (len, d2) ← decodeUnsignedCBOR d1 addInfo
      let (bytes, d3) ← d2.readBytes len
      .ok (.byteString bytes, d3)

  | 3 =>  -- Text string
      let (len, d2) ← decodeUnsignedCBOR d1 addInfo
      let (bytes, d3) ← d2.readBytes len
      let str := String.fromUTF8Unchecked bytes
      .ok (.textString str, d3)

  | 4 =>  -- Array
      let (len, d2) ← decodeUnsignedCBOR d1 addInfo
      let rec decodeItems (n : Nat) (acc : List CBORValue) (decoder : CBORDecoder) : Except String (List CBORValue × CBORDecoder) :=
        if n == 0 then
          .ok (acc.reverse, decoder)
        else do
          let (item, decoder') ← decodeCBORValue decoder
          decodeItems (n - 1) (item :: acc) decoder'
      let (items, d3) ← decodeItems len [] d2
      .ok (.array items, d3)

  | 5 =>  -- Map
      let (len, d2) ← decodeUnsignedCBOR d1 addInfo
      let rec decodePairs (n : Nat) (acc : List (CBORValue × CBORValue)) (decoder : CBORDecoder) : Except String (List (CBORValue × CBORValue) × CBORDecoder) :=
        if n == 0 then
          .ok (acc.reverse, decoder)
        else do
          let (key, decoder1) ← decodeCBORValue decoder
          let (val, decoder2) ← decodeCBORValue decoder1
          decodePairs (n - 1) ((key, val) :: acc) decoder2
      let (pairs, d3) ← decodePairs len [] d2
      .ok (.map pairs, d3)

  | 6 =>  -- Tagged value
      let (tag, d2) ← decodeUnsignedCBOR d1 addInfo
      let (value, d3) ← decodeCBORValue d2
      .ok (.tag tag value, d3)

  | 7 =>  -- Simple/Float
      if addInfo < 24 then
        .ok (.simple addInfo.toNat, d1)
      else if addInfo == 24 then
        do
          let (b, d2) ← d1.readByte
          .ok (.simple b.toNat, d2)
      else if addInfo == 26 then
        -- Single-precision float (32-bit)
        do
          let (bytes, d2) ← d1.readBytes 4
          let bits := UInt32.fromLittleEndian bytes
          let f := Float.ofBits bits.toUInt64
          .ok (.float f, d2)
      else if addInfo == 27 then
        -- Double-precision float (64-bit)
        do
          let (bytes, d2) ← d1.readBytes 8
          let bits := UInt64.fromLittleEndian bytes
          let f := Float.ofBits bits
          .ok (.float f, d2)
      else
        .error s!"Unsupported simple/float encoding: {addInfo}"

  | _ =>
      .error s!"Invalid CBOR major type: {majorType}"

/-- Decode CBOR bytes to value -/
def decodeCBOR (bytes : ByteArray) : Except String CBORValue := do
  let decoder : CBORDecoder := { bytes := bytes, position := 0 }
  let (value, _) ← decodeCBORValue decoder
  .ok value

-- ============================================================================
-- Binary Format (FormDB Native)
-- ============================================================================

/-- Binary format for high-performance storage

    Format:
    - 1 byte: Type tag (discriminator)
    - N bytes: Value data (type-specific)
    - M bytes: Proof blob (optional, for audit)
-/
def serializeTypedValueBinary (tv : Σ t : TypeExpr, TypedValue t) : ByteArray :=
  match tv with
  | ⟨.nat, .nat n⟩ =>
      -- Tag (0x01) + 8 bytes little-endian
      let tag : UInt8 := 0x01
      let valueBytes := n.toUInt64.toLittleEndian
      #[tag] ++ valueBytes

  | ⟨.boundedNat min max, .boundedNat _ _ bn⟩ =>
      -- Tag (0x02) + min (8 bytes) + max (8 bytes) + value (8 bytes)
      let tag : UInt8 := 0x02
      let minBytes := min.toUInt64.toLittleEndian
      let maxBytes := max.toUInt64.toLittleEndian
      let valBytes := bn.val.toUInt64.toLittleEndian
      #[tag] ++ minBytes ++ maxBytes ++ valBytes

  | ⟨.nonEmptyString, .nonEmptyString nes⟩ =>
      -- Tag (0x03) + length (4 bytes) + UTF-8 bytes
      let tag : UInt8 := 0x03
      let utf8 := nes.val.toUTF8
      let lenBytes := utf8.size.toUInt32.toLittleEndian
      #[tag] ++ lenBytes ++ utf8

  | _ => #[]  -- TODO: Complete binary encoding

/-- Deserialize from binary format -/
def deserializeTypedValueBinary (bytes : ByteArray) : Except String (Σ t : TypeExpr, TypedValue t) :=
  if bytes.isEmpty then
    return .error "Empty byte array"

  let tag := bytes.get! 0

  match tag with
  | 0x01 =>  -- Nat
      if bytes.size < 9 then
        return .error "Insufficient bytes for Nat"
      let n := UInt64.fromLittleEndian (bytes.extract 1 9)
      .ok ⟨.nat, .nat n.toNat⟩

  | 0x02 =>  -- BoundedNat
      if bytes.size < 25 then
        return .error "Insufficient bytes for BoundedNat"
      let min := UInt64.fromLittleEndian (bytes.extract 1 9)
      let max := UInt64.fromLittleEndian (bytes.extract 9 17)
      let val := UInt64.fromLittleEndian (bytes.extract 17 25)
      -- TODO: Verify bounds and create with proof
      sorry

  | 0x03 =>  -- NonEmptyString
      if bytes.size < 5 then
        return .error "Insufficient bytes for NonEmptyString"
      let len := UInt32.fromLittleEndian (bytes.extract 1 5)
      if bytes.size < 5 + len.toNat then
        return .error "Insufficient bytes for string data"
      let utf8 := bytes.extract 5 (5 + len.toNat)
      let s := String.fromUTF8Unchecked utf8
      if s.length > 0 then
        .ok ⟨.nonEmptyString, .nonEmptyString (NonEmptyString.mk s sorry)⟩
      else
        .error "Empty string in NonEmptyString"

  | _ => .error s!"Unknown type tag: {tag}"

-- ============================================================================
-- Database-Native Format (SQL Compatibility)
-- ============================================================================

/-- Convert TypedValue to SQL-compatible representation

    WARNING: This LOSES type information!
    Only use for SQL compatibility layer.
-/
def toSQLValue (tv : Σ t : TypeExpr, TypedValue t) : String :=
  match tv with
  | ⟨_, .nat n⟩ => toString n
  | ⟨_, .boundedNat _ _ bn⟩ => toString bn.val  -- BOUNDS LOST!
  | ⟨_, .nonEmptyString nes⟩ => s!"'{nes.val}'"  -- PROOF LOST!
  | ⟨_, .confidence c⟩ => toString c.val  -- TYPE LOST!
  | _ => "NULL"

/-- Convert from SQL value to TypedValue (requires type hint) -/
def fromSQLValue (sqlValue : String) (expectedType : TypeExpr) : Except String (Σ t : TypeExpr, TypedValue t) :=
  match expectedType with
  | .nat =>
      match sqlValue.toNat? with
      | some n => .ok ⟨.nat, .nat n⟩
      | none => .error s!"Cannot parse '{sqlValue}' as Nat"

  | .boundedNat min max =>
      match sqlValue.toNat? with
      | some n =>
          if min ≤ n && n ≤ max then
            .ok ⟨.boundedNat min max, .boundedNat min max (BoundedNat.mk min max n sorry sorry)⟩
          else
            .error s!"Value {n} out of bounds [{min}, {max}]"
      | none => .error s!"Cannot parse '{sqlValue}' as BoundedNat"

  | .nonEmptyString =>
      -- Remove quotes if present
      let s := if sqlValue.startsWith "'" && sqlValue.endsWith "'" then
        sqlValue.drop 1 |>.dropRight 1
      else
        sqlValue
      if s.length > 0 then
        .ok ⟨.nonEmptyString, .nonEmptyString (NonEmptyString.mk s sorry)⟩
      else
        .error "Empty string for NonEmptyString"

  | _ => .error s!"Unsupported type for SQL conversion: {expectedType}"

-- ============================================================================
-- Round-Trip Tests
-- ============================================================================

/-- Test: JSON round-trip (serialize → deserialize = identity) -/
def testJSONRoundTrip (tv : Σ t : TypeExpr, TypedValue t) : Bool :=
  let json := serializeTypedValueJSON tv
  match deserializeTypedValueJSON json with
  | .ok tv' => true  -- TODO: Check equality
  | .error _ => false

/-- Test: Binary round-trip -/
def testBinaryRoundTrip (tv : Σ t : TypeExpr, TypedValue t) : Bool :=
  let bytes := serializeTypedValueBinary tv
  match deserializeTypedValueBinary bytes with
  | .ok tv' => true  -- TODO: Check equality
  | .error _ => false

-- ============================================================================
-- Format Selection
-- ============================================================================

-- SerializationFormat imported from FbqlDt.Serialization.Types

/-- Convert JSON to UTF-8 bytes -/
def jsonToBytes (json : JsonValue) : ByteArray :=
  let rec stringify (j : JsonValue) : String :=
    match j with
    | .object fields =>
        let pairs := fields.map fun (k, v) => s!"\"{k}\":{stringify v}"
        "{" ++ String.intercalate "," pairs ++ "}"
    | .array items =>
        let items := items.map stringify
        "[" ++ String.intercalate "," items ++ "]"
    | .string s => s!"\"{s}\""
    | .number n => toString n
    | .bool true => "true"
    | .bool false => "false"
    | .null => "null"
  (stringify json).toUTF8

/-- Parse JSON from UTF-8 bytes -/
def bytesToJson (bytes : ByteArray) : Except String JsonValue :=
  -- TODO: Full JSON parser (for now, stub)
  .error "JSON parsing not yet implemented"

/-- Serialize TypedValue to specified format -/
def serialize (format : SerializationFormat) (tv : Σ t : TypeExpr, TypedValue t) : ByteArray :=
  match format with
  | .json => jsonToBytes (serializeTypedValueJSON tv)
  | .cbor => encodeCBOR (serializeTypedValueCBOR tv)
  | .binary => serializeTypedValueBinary tv
  | .sql => toSQLValue tv |>.toUTF8

/-- Deserialize TypedValue from CBOR -/
def deserializeTypedValueFromCBOR (cbor : CBORValue) : Except String (Σ t : TypeExpr, TypedValue t) :=
  match cbor with
  | .unsigned n =>
      .ok ⟨.nat, .nat n⟩

  | .tag tag value =>
      if tag == cborTagBoundedNat then
        match value with
        | .map fields =>
            -- Extract min, max, value
            let min? := fields.find? fun (k, _) => k == .textString "min"
            let max? := fields.find? fun (k, _) => k == .textString "max"
            let val? := fields.find? fun (k, _) => k == .textString "value"
            match min?, max?, val? with
            | some (_, .unsigned min), some (_, .unsigned max), some (_, .unsigned val) =>
                if min ≤ val && val ≤ max then
                  .ok ⟨.boundedNat min max, .boundedNat min max (BoundedNat.mk min max val sorry sorry)⟩
                else
                  .error s!"Value {val} out of bounds [{min}, {max}]"
            | _, _, _ => .error "Invalid BoundedNat CBOR structure"
        | _ => .error "BoundedNat tag expects map value"

      else if tag == cborTagNonEmptyString then
        match value with
        | .map fields =>
            let val? := fields.find? fun (k, _) => k == .textString "value"
            match val? with
            | some (_, .textString s) =>
                if s.length > 0 then
                  .ok ⟨.nonEmptyString, .nonEmptyString (NonEmptyString.mk s sorry)⟩
                else
                  .error "Empty string for NonEmptyString"
            | _ => .error "Invalid NonEmptyString CBOR structure"
        | _ => .error "NonEmptyString tag expects map value"

      else if tag == cborTagConfidence then
        match value with
        | .map fields =>
            let val? := fields.find? fun (k, _) => k == .textString "value"
            match val? with
            | some (_, .unsigned n) =>
                if n ≤ 100 then
                  .ok ⟨.confidence, .confidence (BoundedNat.mk 0 100 n sorry sorry)⟩
                else
                  .error s!"Confidence {n} out of bounds [0, 100]"
            | _ => .error "Invalid Confidence CBOR structure"
        | _ => .error "Confidence tag expects map value"

      else
        .error s!"Unknown CBOR tag: {tag}"

  | .textString s =>
      -- Default: assume string type
      if s.length > 0 then
        .ok ⟨.nonEmptyString, .nonEmptyString (NonEmptyString.mk s sorry)⟩
      else
        .error "Empty string"

  | _ => .error "Unsupported CBOR type for TypedValue"

/-- Deserialize TypedValue from specified format -/
def deserialize (format : SerializationFormat) (bytes : ByteArray) (expectedType : TypeExpr) : Except String (Σ t : TypeExpr, TypedValue t) :=
  match format with
  | .json => do
      let json ← bytesToJson bytes
      deserializeTypedValueJSON json

  | .cbor => do
      let cbor ← decodeCBOR bytes
      deserializeTypedValueFromCBOR cbor

  | .binary => deserializeTypedValueBinary bytes

  | .sql => fromSQLValue (String.fromUTF8Unchecked bytes) expectedType

end FbqlDt.Serialization
