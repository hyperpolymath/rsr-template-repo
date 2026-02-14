-- SPDX-License-Identifier: PMPL-1.0-or-later
-- Trustfile template - cryptographic and provenance verification
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <jonathan.jewell@open.ac.uk>
--
-- This template embeds the canonical user-security-requirements specification
-- and provides verification functions for policy hashes, schema signatures,
-- post-quantum signatures, and migration provenance.
--
-- Run: runhaskell .machine_readable/contractiles/trust/Trustfile.hs

module Trustfile where

import Control.Monad (forM)
import System.Directory (doesFileExist)
import System.Environment (lookupEnv)
import System.Exit (exitFailure, exitSuccess)
import System.Process (readProcessWithExitCode)

-- ==========================================================================
-- USER SECURITY REQUIREMENTS SPECIFICATION
-- ==========================================================================
--
-- Canonical source: (define user-security-requirements ...) in Scheme
-- This block is the authoritative crypto policy for all hyperpolymath repos.
-- Customise file paths and verification targets per project; do NOT weaken
-- the algorithm choices below.
--
-- (define user-security-requirements
--   '(
--     ;; Category, Algorithm/Standard, NIST/FIPS Standard, Notes
--     (PasswordHashing "Argon2id (512 MiB, 8 iter, 4 lanes)" "—"
--       "Max memory/iterations for GPU/ASIC resistance; aligns with proactive security stance.")
--     (GeneralHashing "SHAKE3-512 (512-bit output)" "FIPS 202"
--       "Post-quantum; use for provenance, key derivation, and long-term storage.")
--     (PQSignatures "Dilithium5-AES (hybrid)" "ML-DSA-87 (FIPS 204)"
--       "Hybrid with AES-256 for belt-and-suspenders security. SPHINCS+ as conservative backup.")
--     (PQKeyExchange "Kyber-1024 + SHAKE256-KDF" "ML-KEM-1024 (FIPS 203)"
--       "Kyber-1024 for KEM, SHAKE256 for key derivation. SPHINCS+ as backup.")
--     (ClassicalSigs "Ed448 + Dilithium5 (hybrid)" "—"
--       "Ed448 for classical compatibility; Dilithium5 for PQ. SPHINCS+ as backup. Terminate Ed25519/SHA-1 immediately.")
--     (Symmetric "XChaCha20-Poly1305 (256-bit key)" "—"
--       "Larger nonce space; 256-bit keys for quantum margin.")
--     (KeyDerivation "HKDF-SHAKE512" "FIPS 202"
--       "Post-quantum KDF; use with all secret key material.")
--     (RNG "ChaCha20-DRBG (512-bit seed)" "SP 800-90Ar1"
--       "CSPRNG for deterministic, high-entropy needs.")
--     (UserFriendlyHashNames "Base32(SHAKE256(hash)) → Wordlist" "—"
--       "Memorable, deterministic mapping (e.g., \"Gigantic-Giraffe-7\" for drivers).")
--     (DatabaseHashing "BLAKE3 (512-bit) + SHAKE3-512" "—"
--       "BLAKE3 for speed, SHAKE3-512 for long-term storage (semantic XML/ARIA tags).")
--     (SemanticXMLGraphQL "Virtuoso (VOS) + SPARQL 1.2" "—"
--       "Supports WCAG 2.3 AAA, ARIA, and formal verification for accessibility/compliance.")
--     (VMExecution "GraalVM (with formal verification)" "—"
--       "Aligns with preference for introspective, reversible design.")
--     (ProtocolStack "QUIC + HTTP/3 + IPv6 (IPv4 disabled)" "—"
--       "Terminate HTTP/1.1, IPv4, and SHA-1 per \"danger zone\" policy.")
--     (Accessibility "WCAG 2.3 AAA + ARIA + Semantic XML" "—"
--       "CSS-first, HTML-second; full compliance with accessibility requirements.")
--     (Fallback "SPHINCS+" "—"
--       "Conservative PQ backup for all hybrid classical+PQ systems; use if primary PQ algorithm is ever compromised.")
--     (FormalVerification "Coq/Isabelle (for crypto primitives)" "—"
--       "Proactive attestation and transparent logic per system design principles.")
--   )
-- )

-- ==========================================================================
-- FILE PATHS (customise per project)
-- ==========================================================================

policyPath :: FilePath
policyPath = "policy/policy.ncl"

policyHashPath :: FilePath
policyHashPath = "policy/policy.ncl.sha256"

schemaPath :: FilePath
schemaPath = "schema/schema.json"

schemaSigPath :: FilePath
schemaSigPath = "schema/schema.sig"

schemaPubPath :: FilePath
schemaPubPath = "schema/schema.pub"

driverPaths :: [FilePath]
driverPaths = ["drivers/gateway-driver.bin"]

migrationsPath :: FilePath
migrationsPath = "migrations/provenance.json"

migrationsSigPath :: FilePath
migrationsSigPath = "migrations/provenance.sig"

migrationsPubPath :: FilePath
migrationsPubPath = "migrations/provenance.pub"

-- ==========================================================================
-- UTILITIES
-- ==========================================================================

runCmd :: String -> [String] -> IO Bool
runCmd cmd args = do
  (code, _out, _err) <- readProcessWithExitCode cmd args ""
  pure (code == mempty)

readFirstWord :: FilePath -> IO (Maybe String)
readFirstWord path = do
  exists <- doesFileExist path
  if not exists
    then pure Nothing
    else do
      content <- readFile path
      pure (case words content of
        [] -> Nothing
        (w:_) -> Just w)

-- ==========================================================================
-- VERIFICATION FUNCTIONS
-- ==========================================================================

-- | Verify policy file hash.
-- Current: SHA-256 (interim)
-- Target: SHAKE3-512 (FIPS 202) when tooling supports it
verifyPolicyHash :: IO Bool
verifyPolicyHash = do
  expected <- readFirstWord policyHashPath
  case expected of
    Nothing -> pure False
    Just hash -> do
      (code, out, _err) <- readProcessWithExitCode "sha256sum" [policyPath] ""
      if code /= mempty
        then pure False
        else do
          let actual = case words out of
                [] -> ""
                (w:_) -> w
          pure (actual == hash)

-- | Verify schema signature.
-- Current: OpenSSL RSA/DSA (interim)
-- Target: Ed448 + Dilithium5 hybrid when tooling supports it
verifySchemaSignature :: IO Bool
verifySchemaSignature = do
  filesOk <- and <$> mapM doesFileExist [schemaPath, schemaSigPath, schemaPubPath]
  if not filesOk
    then pure False
    else runCmd "openssl" ["dgst", "-sha256", "-verify", schemaPubPath, "-signature", schemaSigPath, schemaPath]

-- | Verify Kyber-1024 post-quantum signatures.
-- Uses ML-KEM-1024 (FIPS 203) when available.
-- Fallback: SPHINCS+ if Kyber tooling unavailable.
verifyKyber1024Signatures :: IO Bool
verifyKyber1024Signatures = do
  cmd <- lookupEnv "KYBER_VERIFY_CMD"
  let kyberCmd = maybe "kyber-verify" id cmd
  results <- forM driverPaths $ \path -> do
    let sig = path <> ".sig"
    let pub = path <> ".pub"
    filesOk <- and <$> mapM doesFileExist [path, sig, pub]
    if not filesOk
      then pure False
      else runCmd kyberCmd ["--pub", pub, "--sig", sig, "--file", path]
  pure (and results)

-- | Verify migration provenance chain.
verifyMigrationProvenance :: IO Bool
verifyMigrationProvenance = do
  filesOk <- and <$> mapM doesFileExist [migrationsPath, migrationsSigPath, migrationsPubPath]
  if not filesOk
    then pure False
    else runCmd "openssl" ["dgst", "-sha256", "-verify", migrationsPubPath, "-signature", migrationsSigPath, migrationsPath]

-- ==========================================================================
-- MAIN
-- ==========================================================================

main :: IO ()
main = do
  putStrLn "=== Trust Verification ==="
  policyOk <- verifyPolicyHash
  putStrLn $ "  Policy hash:    " ++ show policyOk
  schemaOk <- verifySchemaSignature
  putStrLn $ "  Schema sig:     " ++ show schemaOk
  driversOk <- verifyKyber1024Signatures
  putStrLn $ "  PQ signatures:  " ++ show driversOk
  migrationsOk <- verifyMigrationProvenance
  putStrLn $ "  Provenance:     " ++ show migrationsOk
  let allOk = and [policyOk, schemaOk, driversOk, migrationsOk]
  putStrLn $ "=== Result: " ++ (if allOk then "ALL PASSED" else "FAILURES DETECTED") ++ " ==="
  if allOk
    then exitSuccess
    else exitFailure
