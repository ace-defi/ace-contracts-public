// Read-only verification. No wallets, signing keys, dotenv, or transaction sends.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { createHash } = require("node:crypto");
const { Interface, defaultAbiCoder } = require("@ethersproject/abi");
const { keccak256 } = require("@ethersproject/keccak256");

const root = path.resolve(__dirname, "..");
const manifest = require("../deployments/hyperevm-20261113.json");
const endpoint = process.env.HYPEREVM_RPC_URL || "https://rpc.hyperliquid.xyz/evm";
const offline = process.argv.includes("--offline");
const sha256 = (bytes) => createHash("sha256").update(bytes).digest("hex");
const read = (file) => JSON.parse(fs.readFileSync(file, "utf8"));
const sameHex = (actual, expected, label) =>
  assert.equal(actual.toLowerCase(), expected.toLowerCase(), label);

async function rpc(method, params) {
  assert([
    "eth_chainId", "eth_getBlockByNumber", "eth_getCode", "eth_call",
    "eth_getTransactionByHash", "eth_getTransactionReceipt",
  ].includes(method), "Only read-only RPC methods are allowed");
  const response = await fetch(endpoint, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
    signal: AbortSignal.timeout(15000),
  });
  assert(response.ok, `RPC HTTP ${response.status}`);
  const body = await response.json();
  assert(!body.error && body.result != null, `${method}: RPC result unavailable`);
  return body.result;
}

function variableNames(build) {
  const names = new Map();
  function walk(value) {
    if (!value || typeof value !== "object") return;
    if (value.nodeType === "VariableDeclaration" && value.mutability === "immutable") {
      names.set(String(value.id), value.name);
    }
    for (const child of Object.values(value)) walk(child);
  }
  for (const source of Object.values(build.output.sources)) walk(source.ast);
  return names;
}

async function main() {
  for (const [file, expected] of Object.entries(manifest.sourceSha256)) {
    const relative = file.startsWith("@") ? `node_modules/${file}` : file;
    assert.equal(sha256(fs.readFileSync(path.join(root, relative))), expected, file);
  }
  let head;
  if (!offline) {
    assert.equal(Number(BigInt(await rpc("eth_chainId", []))), manifest.chainId);
    head = await rpc("eth_getBlockByNumber", ["latest", false]);
    const age = Date.now() / 1000 - Number(BigInt(head.timestamp));
    assert(age >= -30 && age <= 120, "RPC head is stale or in the future");
  }
  const report = {
    checkedAt: new Date().toISOString(), chainId: manifest.chainId,
    mode: offline ? "offline-build-only" : "build-and-chain",
    rpcHost: offline ? null : new URL(endpoint).hostname,
    block: head ? { number: Number(BigInt(head.number)), hash: head.hash, timestamp: Number(BigInt(head.timestamp)) } : null,
    contracts: {},
  };
  for (const [name, expected] of Object.entries(manifest.contracts)) {
    const artifactDir = path.join(root, "artifacts", expected.sourceName);
    const artifact = read(path.join(artifactDir, `${name}.json`));
    const debug = read(path.join(artifactDir, `${name}.dbg.json`));
    const build = read(path.resolve(artifactDir, debug.buildInfo));
    assert.equal(build.solcLongVersion, manifest.compiler.version);
    for (const field of ["optimizer", "viaIR", "metadata"]) {
      assert.deepEqual(build.input.settings[field], manifest.compiler[field]);
    }
    assert.equal(build.input.settings.evmVersion || "paris", manifest.compiler.evmVersion);
    for (const file of expected.sourceClosure) {
      assert.equal(sha256(build.input.sources[file].content), manifest.sourceSha256[file], `compiled ${file}`);
    }
    const compiled = build.output.contracts[expected.sourceName][name];
    const iface = new Interface(artifact.abi);
    const creation = artifact.bytecode + iface.encodeDeploy(expected.constructorArgs).slice(2);
    sameHex(keccak256(artifact.bytecode), expected.creationBytecodeHash, `${name} creation template`);
    sameHex(keccak256(creation), expected.creationDataHash, `${name} constructor input`);
    sameHex(keccak256(artifact.deployedBytecode), expected.runtimeTemplateHash, `${name} runtime template`);
    const runtime = Buffer.from(artifact.deployedBytecode.slice(2), "hex");
    const names = variableNames(build);
    const used = new Set();
    for (const [id, ranges] of Object.entries(compiled.evm.deployedBytecode.immutableReferences)) {
      const variable = names.get(id);
      assert(Object.hasOwn(expected.immutables, variable), `Unknown immutable ${id}/${variable}`);
      used.add(variable);
      const value = Buffer.from(expected.immutables[variable].slice(2).padStart(64, "0"), "hex");
      for (const { start, length } of ranges) {
        assert.equal(length, value.length);
        assert(start >= 0 && start + length <= runtime.length);
        value.copy(runtime, start);
      }
    }
    assert.deepEqual([...used].sort(), Object.keys(expected.immutables).sort());
    assert.equal(runtime.length, expected.runtimeBytes);
    sameHex(keccak256(runtime), expected.runtimeCodeHash, `${name} full runtime`);
    if (name === "GovernedScheduledMarketJudgeFacet") {
      const imm = expected.immutables;
      const bindings = keccak256(defaultAbiCoder.encode(
        ["uint256", "address", "address", "address", "address"],
        [manifest.chainId, imm.nativeController, imm.usdcController, imm.nativeVault, imm.usdcVault],
      ));
      sameHex(bindings, imm.bindingsHash, "Controller/Vault bindings");
    }
    if (!offline) {
      const tx = await rpc("eth_getTransactionByHash", [expected.transactionHash]);
      const receipt = await rpc("eth_getTransactionReceipt", [expected.transactionHash]);
      sameHex(tx.hash, expected.transactionHash, "Creation transaction hash");
      assert.equal(tx.to, null, "Expected direct CREATE deployment");
      sameHex(tx.input, creation, `${name} mined creation input`);
      assert.equal(Number(BigInt(receipt.status)), 1);
      sameHex(receipt.contractAddress, expected.address, "Created address");
      assert.equal(Number(BigInt(receipt.blockNumber)), expected.blockNumber);
      sameHex(receipt.blockHash, expected.blockHash, "Creation block hash");
      const code = await rpc("eth_getCode", [expected.address, head.number]);
      sameHex(code, `0x${runtime.toString("hex")}`, `${name} full deployed bytes`);
      if (name === "GovernedScheduledMarketJudgeFacet") {
        const loupe = new Interface(["function facetFunctionSelectors(address) view returns (bytes4[])"]);
        const data = loupe.encodeFunctionData("facetFunctionSelectors", [expected.address]);
        const raw = await rpc("eth_call", [{ to: manifest.judge, data }, head.number]);
        const installed = [...loupe.decodeFunctionResult("facetFunctionSelectors", raw)[0]].sort();
        // Deployment exposes this binding getter on the facet itself, not the diamond.
        const facetOnly = iface.getSighash("sharedControllerBindingsHash()");
        const selectors = Object.keys(iface.functions).map((signature) => iface.getSighash(signature))
          .filter((selector) => selector !== facetOnly).sort();
        assert.deepEqual(installed, [...manifest.facetSelectors].sort(), "Active Diamond selector set");
        assert.deepEqual(installed, selectors, "Compiled ABI selector set");
        const bindingResult = await rpc("eth_call", [{ to: expected.address, data: facetOnly }, head.number]);
        sameHex(bindingResult, expected.immutables.bindingsHash, "Facet-only bindings getter");
        report.facetSelectorCount = installed.length;
      }
    }
    report.contracts[name] = { address: expected.address, runtimeBytes: runtime.length, runtimeCodeHash: keccak256(runtime), passed: true };
  }
  if (!offline) {
    const receipt = await rpc("eth_getTransactionReceipt", [manifest.upgrade.hash]);
    assert.equal(Number(BigInt(receipt.status)), 1);
    assert.equal(Number(BigInt(receipt.blockNumber)), manifest.upgrade.blockNumber);
    sameHex(receipt.blockHash, manifest.upgrade.blockHash, "Upgrade block hash");
  }
  report.passed = true;
  console.log(JSON.stringify(report, null, 2));
}

main().catch((error) => {
  // Never print a URL or an RPC error body that could contain credentials.
  console.error(`Verification failed: ${error.name}: ${error.message.replace(/https?:\/\/\S+/g, "[endpoint]")}`);
  process.exitCode = 1;
});
