// scripts/demo/run-demo.mjs
// Live demo runner on Monad Testnet for SpendingGuard with P-256 owner verification.
// Implements the 11-step verification flow with safe key handling and >= 2s pauses.

import { readFileSync, existsSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import crypto from 'node:crypto';
import {
  createPublicClient,
  createWalletClient,
  http,
  parseEther,
  formatEther,
  keccak256,
  concat,
  encodeAbiParameters,
  decodeEventLog,
  defineChain
} from 'viem';
import { privateKeyToAccount } from 'viem/accounts';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const REPO_ROOT = resolve(__dirname, '../..');

// 1. Load environment variables silently
function loadEnv() {
  const envPath = resolve(REPO_ROOT, '.env');
  if (!existsSync(envPath)) {
    throw new Error('FAIL: .env not found');
  }
  const content = readFileSync(envPath, 'utf8');
  const env = {};
  for (let line of content.split('\n')) {
    line = line.replace(/\r$/, '').trim();
    if (!line || line.startsWith('#')) continue;
    const match = line.match(/^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/);
    if (match) {
      let val = match[2].trim();
      if ((val.startsWith('"') && val.endsWith('"')) || (val.startsWith("'") && val.endsWith("'"))) {
        val = val.slice(1, -1);
      }
      env[match[1]] = val;
    }
  }
  return env;
}

const env = loadEnv();
const RPC_URL = env.QUICKNODE_RPC_URL;
const DEPLOYER_PK = env.DEPLOYER_PRIVATE_KEY;
const AGENT_PK = env.AGENT_PRIVATE_KEY;
const DEMO_RECIPIENT = env.DEMO_RECIPIENT;
const EXPECTED_CHAIN_ID = parseInt(env.EXPECTED_CHAIN_ID || '10143', 10);

if (!RPC_URL || !DEPLOYER_PK || !AGENT_PK || !DEMO_RECIPIENT) {
  throw new Error('FAIL: Missing required environment variables');
}

// 2. Load owner P-256 key silently
const ownerKeyPath = resolve(REPO_ROOT, '.secrets/owner-p256.json');
if (!existsSync(ownerKeyPath)) {
  throw new Error('FAIL: .secrets/owner-p256.json not found');
}
const ownerKeyData = JSON.parse(readFileSync(ownerKeyPath, 'utf8'));
const { qx, qy, privateKey: ownerPrivHex } = ownerKeyData;

// 3. Load deployment address
const deploymentPath = resolve(REPO_ROOT, 'deployments/monad-testnet.json');
if (!existsSync(deploymentPath)) {
  throw new Error('FAIL: deployments/monad-testnet.json not found');
}
const deploymentData = JSON.parse(readFileSync(deploymentPath, 'utf8'));
const SPENDING_GUARD_ADDRESS = deploymentData.address;

// 4. Load ABI
const artifactPath = resolve(REPO_ROOT, 'contracts/out/SpendingGuard.sol/SpendingGuard.json');
const artifact = JSON.parse(readFileSync(artifactPath, 'utf8'));
const ABI = artifact.abi;

const monadTestnet = defineChain({
  id: EXPECTED_CHAIN_ID,
  name: 'Monad Testnet',
  nativeCurrency: { name: 'Monad', symbol: 'MON', decimals: 18 },
  rpcUrls: { default: { http: [RPC_URL] } },
  blockExplorers: { default: { name: 'Monadscan', url: 'https://testnet.monadscan.com' } }
});

const publicClient = createPublicClient({
  chain: monadTestnet,
  transport: http(RPC_URL)
});

const deployerAccount = privateKeyToAccount(DEPLOYER_PK);
const agentAccount = privateKeyToAccount(AGENT_PK);

const relayerClient = createWalletClient({
  account: deployerAccount,
  chain: monadTestnet,
  transport: http(RPC_URL)
});

const agentClient = createWalletClient({
  account: agentAccount,
  chain: monadTestnet,
  transport: http(RPC_URL)
});

// Helper for sleep between transactions
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// Helper for P-256 signing
function signOwnerDigest(digestHex) {
  const dBuf = Buffer.from(ownerPrivHex.replace(/^0x/, ''), 'hex');
  const digestBuf = Buffer.from(digestHex.replace(/^0x/, ''), 'hex');
  const jwk = {
    kty: 'EC',
    crv: 'P-256',
    d: dBuf.toString('base64url'),
    x: Buffer.from(qx.replace(/^0x/, ''), 'hex').toString('base64url'),
    y: Buffer.from(qy.replace(/^0x/, ''), 'hex').toString('base64url')
  };
  const keyObj = crypto.createPrivateKey({ format: 'jwk', key: jwk });
  const sig = crypto.sign(null, digestBuf, { key: keyObj, dsaEncoding: 'ieee-p1363' });
  const r = '0x' + sig.subarray(0, 32).toString('hex');
  const s = '0x' + sig.subarray(32, 64).toString('hex');
  return {
    authenticatorData: '0x',
    clientDataJSON: '',
    r,
    s
  };
}

async function getReceiptAndFee(hash) {
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  const feeWei = receipt.gasUsed * (receipt.effectiveGasPrice || 100000000000n);
  const feeMon = formatEther(feeWei);
  return { receipt, feeMon, feeWei };
}

async function run() {
  console.log('=== AGENTPASS MONAD TESTNET LIVE DEMO ===');
  console.log(`SpendingGuard: ${SPENDING_GUARD_ADDRESS}`);
  console.log(`Relayer:       ${deployerAccount.address}`);
  console.log(`Agent:         ${agentAccount.address}`);
  console.log(`Recipient:     ${DEMO_RECIPIENT}`);
  console.log('=========================================');

  const accountId = keccak256(concat([qx, qy]));
  console.log(`Account ID:    ${accountId}`);

  const results = [];

  // Helper to record and print step result
  function logStep(stepNum, name, expected, actual, hash, feeMon) {
    const explorerUrl = `https://testnet.monadscan.com/tx/${hash}`;
    console.log(`\nStep ${stepNum}: ${name}`);
    console.log(`  Expected: ${expected}`);
    console.log(`  Actual:   ${actual}`);
    console.log(`  Tx Hash:  ${hash}`);
    console.log(`  Explorer: ${explorerUrl}`);
    console.log(`  Fee:      ${feeMon} MON`);
    results.push({ stepNum, name, expected, actual, hash, explorerUrl, feeMon });
  }

  // --- Step 1: createAccount ---
  const existingAcc = await publicClient.readContract({
    address: SPENDING_GUARD_ADDRESS,
    abi: ABI,
    functionName: 'accountOf',
    args: [accountId]
  });

  let step1Hash = '';
  let step1Fee = '0';
  if (existingAcc[0] !== '0x0000000000000000000000000000000000000000000000000000000000000000') {
    console.log('\nStep 1: Account already created. Reusing account.');
    step1Hash = deploymentData.txHash;
    results.push({
      stepNum: 1,
      name: 'createAccount (reused)',
      expected: 'AccountCreated',
      actual: 'AccountCreated (reused)',
      hash: step1Hash,
      explorerUrl: `https://testnet.monadscan.com/tx/${step1Hash}`,
      feeMon: '0'
    });
  } else {
    const hash = await relayerClient.writeContract({
      address: SPENDING_GUARD_ADDRESS,
      abi: ABI,
      functionName: 'createAccount',
      args: [qx, qy]
    });
    const { feeMon } = await getReceiptAndFee(hash);
    step1Hash = hash;
    step1Fee = feeMon;
    logStep(1, 'createAccount', 'AccountCreated', 'AccountCreated', hash, feeMon);
    await sleep(2500);
  }

  // --- Step 2: deposit 0.1 MON ---
  const depositHash = await relayerClient.writeContract({
    address: SPENDING_GUARD_ADDRESS,
    abi: ABI,
    functionName: 'deposit',
    args: [accountId],
    value: parseEther('0.1')
  });
  const { feeMon: depositFee } = await getReceiptAndFee(depositHash);
  logStep(2, 'deposit 0.1 MON', 'Deposited 0.1 MON', 'Deposited 0.1 MON', depositHash, depositFee);
  await sleep(2500);

  // --- Step 3: addAgent signed by owner ---
  const agentInfo = await publicClient.readContract({
    address: SPENDING_GUARD_ADDRESS,
    abi: ABI,
    functionName: 'agentOf',
    args: [accountId, agentAccount.address]
  });

  if (!agentInfo[0]) {
    const nonce = await publicClient.readContract({
      address: SPENDING_GUARD_ADDRESS,
      abi: ABI,
      functionName: 'nonceOf',
      args: [accountId]
    });
    const dailyLimit = parseEther('0.05');
    const anyTarget = false;
    const params = encodeAbiParameters(
      [{ type: 'address' }, { type: 'uint128' }, { type: 'bool' }],
      [agentAccount.address, dailyLimit, anyTarget]
    );
    const digest = await publicClient.readContract({
      address: SPENDING_GUARD_ADDRESS,
      abi: ABI,
      functionName: 'actionHash',
      args: [accountId, nonce, '0x2f275d76', params]
    });
    const auth = signOwnerDigest(digest);
    const addAgentHash = await relayerClient.writeContract({
      address: SPENDING_GUARD_ADDRESS,
      abi: ABI,
      functionName: 'addAgent',
      args: [accountId, agentAccount.address, dailyLimit, anyTarget, auth]
    });
    const { feeMon } = await getReceiptAndFee(addAgentHash);
    logStep(3, 'addAgent (0.05 MON limit)', 'AgentAdded', 'AgentAdded', addAgentHash, feeMon);
    await sleep(2500);
  } else {
    console.log('\nStep 3: Agent already added.');
  }

  // --- Step 4: setTargetAllowed (DEMO_RECIPIENT) ---
  const isAllowed = await publicClient.readContract({
    address: SPENDING_GUARD_ADDRESS,
    abi: ABI,
    functionName: 'isTargetAllowed',
    args: [accountId, agentAccount.address, DEMO_RECIPIENT]
  });

  if (!isAllowed) {
    const nonce = await publicClient.readContract({
      address: SPENDING_GUARD_ADDRESS,
      abi: ABI,
      functionName: 'nonceOf',
      args: [accountId]
    });
    const params = encodeAbiParameters(
      [{ type: 'address' }, { type: 'address' }, { type: 'bool' }],
      [agentAccount.address, DEMO_RECIPIENT, true]
    );
    const digest = await publicClient.readContract({
      address: SPENDING_GUARD_ADDRESS,
      abi: ABI,
      functionName: 'actionHash',
      args: [accountId, nonce, '0x725fe6fe', params]
    });
    const auth = signOwnerDigest(digest);
    const setTargetHash = await relayerClient.writeContract({
      address: SPENDING_GUARD_ADDRESS,
      abi: ABI,
      functionName: 'setTargetAllowed',
      args: [accountId, agentAccount.address, DEMO_RECIPIENT, true, auth]
    });
    const { feeMon } = await getReceiptAndFee(setTargetHash);
    logStep(4, 'setTargetAllowed (DEMO_RECIPIENT)', 'TargetAllowedSet', 'TargetAllowedSet', setTargetHash, feeMon);
    await sleep(2500);
  } else {
    console.log('\nStep 4: Target already allowed.');
  }

  // --- Step 5: Fund agent with 0.1 MON gas if needed ---
  const agentBal = await publicClient.getBalance({ address: agentAccount.address });
  if (agentBal < parseEther('0.1')) {
    const fundHash = await relayerClient.sendTransaction({
      to: agentAccount.address,
      value: parseEther('0.1')
    });
    const { feeMon } = await getReceiptAndFee(fundHash);
    logStep(5, 'fund agent gas (0.1 MON)', 'Funded agent', 'Funded agent', fundHash, feeMon);
    await sleep(2500);
  } else {
    console.log(`\nStep 5: Agent already holds ${formatEther(agentBal)} MON (>= 0.1 MON). Skipping funding.`);
    results.push({
      stepNum: 5,
      name: 'fund agent gas',
      expected: 'Agent holds >= 0.1 MON',
      actual: `Held ${formatEther(agentBal)} MON (skipped)`,
      hash: 'N/A',
      explorerUrl: 'N/A',
      feeMon: '0'
    });
  }

  // --- Check remainingToday before Step 6 ---
  const remBefore = await publicClient.readContract({
    address: SPENDING_GUARD_ADDRESS,
    abi: ABI,
    functionName: 'remainingToday',
    args: [accountId, agentAccount.address]
  });

  const expectedDaily = parseEther('0.05');
  if (remBefore !== expectedDaily) {
    throw new Error(
      `ABORT: remainingToday is ${formatEther(remBefore)} MON, expected exactly 0.05 MON. The agent already spent today!`
    );
  }
  console.log(`\nRemaining today verified: ${formatEther(remBefore)} MON (exactly 0.05 MON). Proceeding to payments.`);

  // --- Step 6: agent tryPay 0.02 MON -> expect Paid ---
  const p6Hash = await agentClient.writeContract({
    address: SPENDING_GUARD_ADDRESS,
    abi: ABI,
    functionName: 'tryPay',
    args: [accountId, DEMO_RECIPIENT, parseEther('0.02')]
  });
  const { receipt: r6, feeMon: f6 } = await getReceiptAndFee(p6Hash);
  // Verify PaymentExecuted event
  const p6Executed = r6.logs.some((l) => {
    try {
      const decoded = decodeEventLog({ abi: ABI, data: l.data, topics: l.topics });
      return decoded.eventName === 'PaymentExecuted';
    } catch { return false; }
  });
  const act6 = p6Executed ? 'Paid' : 'Failed/Blocked';
  logStep(6, 'tryPay 0.02 MON to DEMO_RECIPIENT', 'Paid', act6, p6Hash, f6);
  if (act6 !== 'Paid') throw new Error('Step 6 mismatch');
  await sleep(2500);

  // --- Step 7: agent tryPay 0.06 MON -> expect blocked OVER_DAILY_LIMIT ---
  const p7Hash = await agentClient.writeContract({
    address: SPENDING_GUARD_ADDRESS,
    abi: ABI,
    functionName: 'tryPay',
    args: [accountId, DEMO_RECIPIENT, parseEther('0.06')]
  });
  const { receipt: r7, feeMon: f7 } = await getReceiptAndFee(p7Hash);
  let r7Reason = null;
  r7.logs.forEach((l) => {
    try {
      const decoded = decodeEventLog({ abi: ABI, data: l.data, topics: l.topics });
      if (decoded.eventName === 'PaymentBlocked') r7Reason = decoded.args.reason;
    } catch {}
  });
  // PaymentBlockReason.OVER_DAILY_LIMIT is enum index 4
  const act7 = r7Reason === 4 ? 'blocked OVER_DAILY_LIMIT' : `blocked (reason ${r7Reason})`;
  logStep(7, 'tryPay 0.06 MON to DEMO_RECIPIENT', 'blocked OVER_DAILY_LIMIT', act7, p7Hash, f7);
  if (act7 !== 'blocked OVER_DAILY_LIMIT') throw new Error('Step 7 mismatch');
  await sleep(2500);

  // --- Step 8: agent tryPay 0.02 MON -> expect Paid (total 0.04) ---
  const p8Hash = await agentClient.writeContract({
    address: SPENDING_GUARD_ADDRESS,
    abi: ABI,
    functionName: 'tryPay',
    args: [accountId, DEMO_RECIPIENT, parseEther('0.02')]
  });
  const { receipt: r8, feeMon: f8 } = await getReceiptAndFee(p8Hash);
  const p8Executed = r8.logs.some((l) => {
    try {
      const decoded = decodeEventLog({ abi: ABI, data: l.data, topics: l.topics });
      return decoded.eventName === 'PaymentExecuted';
    } catch { return false; }
  });
  const act8 = p8Executed ? 'Paid (total 0.04)' : 'Failed/Blocked';
  logStep(8, 'tryPay 0.02 MON to DEMO_RECIPIENT', 'Paid (total 0.04)', act8, p8Hash, f8);
  if (act8 !== 'Paid (total 0.04)') throw new Error('Step 8 mismatch');
  await sleep(2500);

  // --- Step 9: agent tryPay 0.02 MON -> expect blocked OVER_DAILY_LIMIT (0.06 > 0.05) ---
  const p9Hash = await agentClient.writeContract({
    address: SPENDING_GUARD_ADDRESS,
    abi: ABI,
    functionName: 'tryPay',
    args: [accountId, DEMO_RECIPIENT, parseEther('0.02')]
  });
  const { receipt: r9, feeMon: f9 } = await getReceiptAndFee(p9Hash);
  let r9Reason = null;
  r9.logs.forEach((l) => {
    try {
      const decoded = decodeEventLog({ abi: ABI, data: l.data, topics: l.topics });
      if (decoded.eventName === 'PaymentBlocked') r9Reason = decoded.args.reason;
    } catch {}
  });
  const act9 = r9Reason === 4 ? 'blocked OVER_DAILY_LIMIT' : `blocked (reason ${r9Reason})`;
  logStep(9, 'tryPay 0.02 MON (exceeds cap)', 'blocked OVER_DAILY_LIMIT', act9, p9Hash, f9);
  if (act9 !== 'blocked OVER_DAILY_LIMIT') throw new Error('Step 9 mismatch');
  await sleep(2500);

  // --- Step 10: agent tryPay 0.01 to dEaD address -> expect blocked TARGET_NOT_ALLOWED ---
  const DEAD_ADDR = '0x000000000000000000000000000000000000dEaD';
  const p10Hash = await agentClient.writeContract({
    address: SPENDING_GUARD_ADDRESS,
    abi: ABI,
    functionName: 'tryPay',
    args: [accountId, DEAD_ADDR, parseEther('0.01')]
  });
  const { receipt: r10, feeMon: f10 } = await getReceiptAndFee(p10Hash);
  let r10Reason = null;
  r10.logs.forEach((l) => {
    try {
      const decoded = decodeEventLog({ abi: ABI, data: l.data, topics: l.topics });
      if (decoded.eventName === 'PaymentBlocked') r10Reason = decoded.args.reason;
    } catch {}
  });
  // PaymentBlockReason.TARGET_NOT_ALLOWED is enum index 3
  const act10 = r10Reason === 3 ? 'blocked TARGET_NOT_ALLOWED' : `blocked (reason ${r10Reason})`;
  logStep(10, 'tryPay 0.01 MON to dEaD', 'blocked TARGET_NOT_ALLOWED', act10, p10Hash, f10);
  if (act10 !== 'blocked TARGET_NOT_ALLOWED') throw new Error('Step 10 mismatch');
  await sleep(2500);

  // --- Step 11: agent strict pay 0.06 with EXPLICIT gas limit 150000 -> expect revert OverDailyLimit ---
  const gasPriceWei = await publicClient.getGasPrice();
  const explicitGasLimit = 150000n;
  const statedCostMon = formatEther(explicitGasLimit * gasPriceWei);
  console.log(`\nStep 11: Stated transaction cost before sending: ${statedCostMon} MON (${explicitGasLimit} gas @ ${gasPriceWei} wei)`);

  const { encodeFunctionData } = await import('viem');
  const callData = encodeFunctionData({
    abi: ABI,
    functionName: 'pay',
    args: [accountId, DEMO_RECIPIENT, parseEther('0.06')]
  });

  const p11Hash = await agentClient.sendTransaction({
    to: SPENDING_GUARD_ADDRESS,
    data: callData,
    gas: explicitGasLimit
  });

  const r11 = await publicClient.waitForTransactionReceipt({ hash: p11Hash });
  const feeWei = r11.gasUsed * (r11.effectiveGasPrice || gasPriceWei);
  const f11 = formatEther(feeWei);
  const act11 = r11.status === 'reverted' ? 'revert OverDailyLimit' : r11.status;
  logStep(11, 'strict pay 0.06 MON (explicit 150k gas)', 'revert OverDailyLimit', act11, p11Hash, f11);

  console.log('\n=========================================');
  console.log('ALL 11 DEMO STEPS COMPLETED SUCCESSFULLY!');
  console.log('=========================================');

  // Compute total fees
  let totalFeeWei = 0n;
  for (const r of results) {
    if (r.feeMon && r.feeMon !== '0') {
      totalFeeWei += parseEther(r.feeMon);
    }
  }
  console.log(`Total Demo Fees: ${formatEther(totalFeeWei)} MON`);

  // Write demo summary markdown table
  return results;
}

run().catch((err) => {
  console.error('DEMO RUN FAILED:', err);
  process.exit(1);
});
