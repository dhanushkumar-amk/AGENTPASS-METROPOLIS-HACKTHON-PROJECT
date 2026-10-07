'use client';

import React, { useEffect, useState } from 'react';
import {
  createPasskey,
  isWebAuthnSupported,
  recoverPublicKeyCandidates,
  signChallenge,
  to0xHex,
  verifyAssertionLocal,
} from '@/lib/passkey';
import type {
  LocalVerificationResult,
  ParsedAssertion,
  PasskeyCreationResult,
  PublicKeyCandidate,
} from '@/lib/passkey';

export default function PasskeySpikePage() {
  const [supported, setSupported] = useState<boolean | null>(null);
  const [rpId, setRpId] = useState('localhost');
  const [origin, setOrigin] = useState('http://localhost:3000');
  const [createdPasskey, setCreatedPasskey] = useState<PasskeyCreationResult | null>(null);
  const [signedAssertion, setSignedAssertion] = useState<ParsedAssertion | null>(null);
  const [activeChallengeHex, setActiveChallengeHex] = useState<string | null>(null);
  const [candidates, setCandidates] = useState<PublicKeyCandidate[]>([]);
  const [realKeyMatches, setRealKeyMatches] = useState<boolean | null>(null);
  const [verificationResult, setVerificationResult] = useState<LocalVerificationResult | null>(null);
  const [errorMessage, setErrorMessage] = useState<string | null>(null);
  const [copyStatus, setCopyStatus] = useState<string | null>(null);
  const [loadingAction, setLoadingAction] = useState<string | null>(null);

  useEffect(() => {
    setSupported(isWebAuthnSupported());
    if (typeof window !== 'undefined') {
      setOrigin(window.location.origin);
      setRpId(window.location.hostname || 'localhost');
    }
  }, []);

  const handleCreatePasskey = async () => {
    setErrorMessage(null);
    setLoadingAction('create');
    try {
      const result = await createPasskey(rpId, 'AgentPass Spike User');
      setCreatedPasskey(result);
      setSignedAssertion(null);
      setVerificationResult(null);
      setCandidates([]);
      setRealKeyMatches(null);
    } catch (err: unknown) {
      const error = err as Error;
      if (error.name === 'NotAllowedError') {
        setErrorMessage('User cancelled or timed out during passkey creation.');
      } else {
        setErrorMessage(`Passkey creation failed: ${error.message}`);
      }
    } finally {
      setLoadingAction(null);
    }
  };

  const handleSignChallenge = async () => {
    setErrorMessage(null);
    setLoadingAction('sign');
    try {
      const challengeBytes = globalThis.crypto.getRandomValues(new Uint8Array(32));
      const challengeHex = to0xHex(challengeBytes, 32);
      setActiveChallengeHex(challengeHex);

      const credentialId = createdPasskey?.credentialId;
      const assertion = await signChallenge(credentialId, challengeBytes, rpId);
      setSignedAssertion(assertion);

      // Recover public key candidates
      const recCandidates = recoverPublicKeyCandidates(
        assertion.authenticatorData,
        assertion.clientDataJSON,
        assertion.r,
        assertion.s
      );
      setCandidates(recCandidates);

      // Check if real key matches one of candidates
      if (createdPasskey) {
        const matches = recCandidates.some(
          (c) =>
            c.qx.hex.toLowerCase() === createdPasskey.qx.hex.toLowerCase() &&
            c.qy.hex.toLowerCase() === createdPasskey.qy.hex.toLowerCase()
        );
        setRealKeyMatches(matches);

        // Perform local verification
        const localCheck = await verifyAssertionLocal({
          authenticatorData: assertion.authenticatorData,
          clientDataJSON: assertion.clientDataJSON,
          r: assertion.r,
          s: assertion.s,
          qx: createdPasskey.qx.bigint,
          qy: createdPasskey.qy.bigint,
          expectedChallenge: challengeBytes,
          expectedRpId: rpId,
        });
        setVerificationResult(localCheck);
      } else {
        setRealKeyMatches(null);
        setVerificationResult(null);
      }
    } catch (err: unknown) {
      const error = err as Error;
      if (error.name === 'NotAllowedError') {
        setErrorMessage('User cancelled or timed out during challenge signing.');
      } else {
        setErrorMessage(`Challenge signing failed: ${error.message}`);
      }
    } finally {
      setLoadingAction(null);
    }
  };

  const handleCopyVector = async () => {
    if (!signedAssertion) return;
    const vector = {
      _description: 'Browser-generated WebAuthn P-256 test vector',
      challenge: activeChallengeHex,
      hash: signedAssertion.digestHex,
      r: signedAssertion.rHex,
      s: signedAssertion.sHex,
      sLow: signedAssertion.sLowHex,
      qx: createdPasskey?.qx.hex ?? candidates[0]?.qx.hex ?? 'unknown',
      qy: createdPasskey?.qy.hex ?? candidates[0]?.qy.hex ?? 'unknown',
      accountId: createdPasskey?.accountId ?? candidates[0]?.accountId ?? 'unknown',
      authenticatorData: signedAssertion.authenticatorDataHex,
      clientDataJSON: signedAssertion.clientDataJSONText,
      typeIndex: signedAssertion.typeIndex,
      challengeIndex: signedAssertion.challengeIndex,
      rpId,
      origin,
    };

    try {
      await navigator.clipboard.writeText(JSON.stringify(vector, null, 2));
      setCopyStatus('Vector JSON copied to clipboard!');
      setTimeout(() => setCopyStatus(null), 3000);
    } catch (err) {
      setCopyStatus(`Failed to copy: ${(err as Error).message}`);
    }
  };

  return (
    <main style={{ maxWidth: 860, margin: '2rem auto', padding: '0 1rem', fontFamily: 'system-ui, sans-serif' }}>
      <h1>AgentPass Passkey & WebAuthn Spike</h1>
      <p style={{ color: '#555' }}>
        Interactive verification spike for Phase 13. Creates WebAuthn passkeys (ES256 on P-256),
        signs 32-byte challenges, extracts precompile verification vectors, and validates locally.
      </p>

      <section style={{ background: '#f5f5f5', padding: '1rem', borderRadius: 6, marginBottom: '1.5rem' }}>
        <strong>Environment Context:</strong>
        <div>RP ID (bound domain): <code>{rpId}</code></div>
        <div>Origin: <code>{origin}</code></div>
        <div>
          WebAuthn Support:{' '}
          {supported === null ? (
            'Checking...'
          ) : supported ? (
            <span style={{ color: 'green', fontWeight: 'bold' }}>Supported (Secure Context)</span>
          ) : (
            <span style={{ color: 'red', fontWeight: 'bold' }}>UNSUPPORTED (Check HTTPS / localhost)</span>
          )}
        </div>
      </section>

      {errorMessage && (
        <div style={{ background: '#ffebee', color: '#c62828', padding: '1rem', borderRadius: 6, marginBottom: '1.5rem' }}>
          <strong>Notice:</strong> {errorMessage}
        </div>
      )}

      <div style={{ display: 'flex', gap: '1rem', marginBottom: '1.5rem', flexWrap: 'wrap' }}>
        <button
          onClick={handleCreatePasskey}
          disabled={loadingAction !== null || supported === false}
          style={{ padding: '0.6rem 1.2rem', fontSize: '1rem', cursor: 'pointer' }}
        >
          {loadingAction === 'create' ? 'Creating passkey...' : '1. Create Passkey'}
        </button>

        <button
          onClick={handleSignChallenge}
          disabled={loadingAction !== null || supported === false}
          style={{ padding: '0.6rem 1.2rem', fontSize: '1rem', cursor: 'pointer' }}
        >
          {loadingAction === 'sign' ? 'Signing challenge...' : '2. Sign Random Challenge'}
        </button>

        {signedAssertion && (
          <button
            onClick={handleCopyVector}
            style={{ padding: '0.6rem 1.2rem', fontSize: '1rem', cursor: 'pointer' }}
          >
            3. Copy Vector JSON
          </button>
        )}
      </div>

      {copyStatus && (
        <div style={{ color: 'green', fontWeight: 'bold', marginBottom: '1rem' }}>
          {copyStatus}
        </div>
      )}

      {createdPasskey && (
        <section style={{ border: '1px solid #ddd', padding: '1rem', borderRadius: 6, marginBottom: '1.5rem' }}>
          <h3>Created Passkey (Owner Identity)</h3>
          <div><strong>Credential ID:</strong> <code style={{ wordBreak: 'break-all' }}>{createdPasskey.credentialId}</code></div>
          <div><strong>qx (Public Key X):</strong> <code>{createdPasskey.qx.hex}</code></div>
          <div><strong>qy (Public Key Y):</strong> <code>{createdPasskey.qy.hex}</code></div>
          <div><strong>Derived Account ID:</strong> <code>{createdPasskey.accountId}</code></div>
          <small style={{ color: '#666' }}>Formula: <code>accountId = keccak256(abi.encode(qx, qy))</code></small>
        </section>
      )}

      {signedAssertion && (
        <section style={{ border: '1px solid #ddd', padding: '1rem', borderRadius: 6, marginBottom: '1.5rem' }}>
          <h3>Assertion Result & Verification Pipeline</h3>

          <div><strong>Challenge:</strong> <code>{activeChallengeHex}</code></div>
          <div style={{ marginTop: '0.5rem' }}>
            <strong>ClientDataJSON:</strong>
            <pre style={{ background: '#eee', padding: '0.5rem', overflowX: 'auto' }}>
              {signedAssertion.clientDataJSONText}
            </pre>
          </div>

          <div><strong>Authenticator Data (Hex):</strong> <code style={{ wordBreak: 'break-all' }}>{signedAssertion.authenticatorDataHex}</code></div>
          <div><strong>typeIndex:</strong> <code>{signedAssertion.typeIndex}</code> (points to <code>&quot;type&quot;:&quot;webauthn.get&quot;</code>)</div>
          <div><strong>challengeIndex:</strong> <code>{signedAssertion.challengeIndex}</code> (points to <code>&quot;challenge&quot;:&quot;</code>)</div>
          <div style={{ marginTop: '0.5rem' }}>
            <strong>Raw Signature Scalars:</strong>
            <div>r: <code>{signedAssertion.rHex}</code></div>
            <div>s: <code>{signedAssertion.sHex}</code> (default raw authenticator output)</div>
            <div>sLow: <code>{signedAssertion.sLowHex}</code> (normalized s &le; n/2)</div>
          </div>

          <div style={{ marginTop: '0.5rem' }}>
            <strong>Precompile Digest (hash):</strong> <code>{signedAssertion.digestHex}</code>
            <div><small style={{ color: '#666' }}>Formula: <code>sha256(authenticatorData || sha256(clientDataJSON))</code></small></div>
          </div>

          <div style={{ marginTop: '1rem' }}>
            <h4>Public Key Candidate Recovery (Phase 16 Login Preview)</h4>
            {candidates.map((cand) => (
              <div key={cand.recoveryBit} style={{ background: '#fafafa', padding: '0.5rem', marginBottom: '0.5rem', borderLeft: '3px solid #ccc' }}>
                <div><strong>Candidate (v={cand.recoveryBit}):</strong></div>
                <div>qx: <code>{cand.qx.hex}</code></div>
                <div>qy: <code>{cand.qy.hex}</code></div>
                <div>accountId: <code>{cand.accountId}</code></div>
              </div>
            ))}
            {realKeyMatches !== null && (
              <div>
                Real Key Matches Candidate:{' '}
                {realKeyMatches ? (
                  <span style={{ color: 'green', fontWeight: 'bold' }}>YES (Candidate matches registered passkey)</span>
                ) : (
                  <span style={{ color: 'red', fontWeight: 'bold' }}>NO</span>
                )}
              </div>
            )}
          </div>

          {verificationResult && (
            <div style={{ marginTop: '1rem', padding: '0.8rem', background: verificationResult.valid ? '#e8f5e9' : '#ffebee', borderRadius: 4 }}>
              <strong>Local Dual Verification Result (WebCrypto + @noble/curves): </strong>
              {verificationResult.valid ? (
                <span style={{ color: 'green', fontWeight: 'bold' }}>VALID</span>
              ) : (
                <span style={{ color: 'red', fontWeight: 'bold' }}>INVALID</span>
              )}
              {verificationResult.reasons.length > 0 && (
                <ul>
                  {verificationResult.reasons.map((reason, i) => (
                    <li key={i} style={{ color: '#c62828' }}>{reason}</li>
                  ))}
                </ul>
              )}
            </div>
          )}
        </section>
      )}

      <footer style={{ marginTop: '3rem', fontSize: '0.85rem', color: '#777', borderTop: '1px solid #eee', paddingTop: '1rem' }}>
        <strong>Security Notice:</strong> No keys or sensitive credentials are saved in localStorage or transmitted to a backend.
        Private keys are stored in secure authenticator hardware and never leave the authenticator.
      </footer>
    </main>
  );
}
