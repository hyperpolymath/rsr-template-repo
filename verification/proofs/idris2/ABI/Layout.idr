-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
--
-- ABI Proof: Memory layout correctness
-- Proves struct size, alignment, and padding properties.
-- All proofs MUST be constructive and total; proof escape hatches are forbidden.

module ABI.Layout

import Data.DPair
import Data.Nat

%default total

||| Witness that a type has a known size in bytes at compile time.
public export
interface HasSize (ty : Type) where
  sizeOf : Nat

||| Witness that a type has a known alignment in bytes.
public export
interface HasAlignment (ty : Type) where
  alignOf : Nat

||| Calculate padding needed to reach the next aligned offset.
||| paddingFor offset alignment = bytes to add so (offset + padding) `mod` alignment == 0
public export
paddingFor : (offset : Nat) -> (alignment : Nat) -> {auto 0 ok : IsSucc alignment} -> Nat
paddingFor offset alignment = let r = modNatNZ offset alignment ok
                              in case r of
                                   Z => Z
                                   (S _) => minus alignment r

||| Proof that an offset with zero remainder needs zero padding.
export
alignedNeedsPadding : (n : Nat) -> (a : Nat) -> {auto 0 ok : IsSucc a} ->
                      modNatNZ n a ok = 0 -> paddingFor n a = 0
alignedNeedsPadding n a prf = rewrite prf in Refl

||| A field within a struct, carrying its offset and size.
public export
record StructField where
  constructor MkField
  fieldName : String
  fieldOffset : Nat
  fieldSize : Nat
  fieldAlignment : Nat

||| `offset` is a multiple of `alignment`, and `alignment` is non-zero.
||| The non-zero witness is part of the claim: an alignment of 0 is not a
||| C alignment, so it must not make a field (or a struct size) "aligned".
||| The witness is erased (`Subset`), so it costs nothing at run time.
public export
Aligned : (offset : Nat) -> (alignment : Nat) -> Type
Aligned offset alignment =
  Subset (IsSucc alignment) (\nz => modNatNZ offset alignment nz = 0)

||| No offset is aligned to 0: the non-zero witness cannot be built.
export
zeroAlignmentNeverAligned : (offset : Nat) -> Not (Aligned offset 0)
zeroAlignmentNeverAligned _ (Element ItIsSucc _) impossible

||| Proof that a field is correctly aligned within a struct.
public export
FieldAligned : StructField -> Type
FieldAligned f = Aligned (fieldOffset f) (fieldAlignment f)

||| Proof that a field does not overflow past a given struct size.
public export
FieldInBounds : (structSize : Nat) -> StructField -> Type
FieldInBounds sz f = LTE (fieldOffset f + fieldSize f) sz

||| A struct layout is a list of fields with a total size.
public export
record StructLayout where
  constructor MkLayout
  layoutName : String
  layoutFields : List StructField
  layoutSize : Nat
  layoutAlignment : Nat
