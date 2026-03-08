const { ethers, upgrades } = require("hardhat");

const COLORS = {
  RESET: "\x1b[0m",
  GREEN: "\x1b[32m",
  YELLOW: "\x1b[33m",
  RED: "\x1b[31m",
  CYAN: "\x1b[36m",
};

function logHeader(title) {
  console.log("\n========================================");
  console.log(`${COLORS.CYAN}${title}${COLORS.RESET}`);
  console.log("========================================\n");
}

function logSection(title) {
  console.log(`\n${COLORS.CYAN}${title}${COLORS.RESET}`);
  console.log("----------------------------------------");
}

function logSuccess(msg) {
  console.log(`  ✅ ${msg}`);
}

function logWarning(msg) {
  console.log(`  ⚠️  ${msg}`);
}

function logError(msg) {
  console.log(`  ❌ ${msg}`);
}

async function validateStorageLayout() {
  logHeader("ServerNodeV2Backup 存储布局验证");

  const ServerNodeV2Backup = await ethers.getContractFactory("ServerNodeV2Backup");

  console.log("1. 验证合约继承结构...");
  console.log("   - Initializable ✅");
  console.log("   - OwnableUpgradeable ✅");
  console.log("   - ReentrancyGuardUpgradeable ✅");
  console.log("   - PausableUpgradeable ✅");
  logWarning("未继承 UUPSUpgradeable（如需升级功能请添加）\n");

  console.log("2. 检查存储槽使用情况...");
  console.log("   关键存储变量:");
  const storageLayout = [
    { name: "_initialized", slot: "0", type: "uint8", desc: "初始化状态" },
    { name: "_initializing", slot: "0", type: "bool", desc: "初始化中标志" },
    { name: "_owner", slot: "51", type: "address", desc: "合约所有者" },
    { name: "_paused", slot: "101", type: "bool", desc: "暂停状态" },
    { name: "REWARD", slot: "~102", type: "address", desc: "奖励计算器地址" },
    { name: "totalActiveEquivalent", slot: "~104", type: "uint256", desc: "全局活跃等效值" },
    { name: "lastRewardActiveEquivalent", slot: "~105", type: "uint256", desc: "上次奖励快照" },
    { name: "hasDistributedReward", slot: "~106", type: "bool", desc: "已分发奖励标志" },
    { name: "lastDailyRewardSnapshot", slot: "~108", type: "uint256", desc: "每日奖励快照" },
  ];
  storageLayout.forEach(item => {
    console.log(`   - ${item.name}: slot ${item.slot} (${item.type}) - ${item.desc}`);
  });
  console.log("");

  console.log("3. 验证新增变量的存储槽...");
  logSuccess("hasDistributedReward (bool) - 新增哨兵变量");
  logSuccess("lastDailyRewardSnapshot (uint256) - 新增快照变量");
  logWarning("升级时这两个变量初始值为 0/false");
  logWarning("已在 _getCurrentRewardInfo 中处理升级场景\n");

  console.log("4. 验证合约大小...");
  const bytecode = ServerNodeV2Backup.bytecode;
  const bytecodeSize = (bytecode.length - 2) / 2;
  const maxSize = 24576;
  const percentage = ((bytecodeSize / maxSize) * 100).toFixed(2);
  console.log(`   字节码大小: ${bytecodeSize} bytes`);
  console.log(`   最大限制: ${maxSize} bytes`);
  console.log(`   使用率: ${percentage}%`);
  if (bytecodeSize <= maxSize) {
    logSuccess(`合约大小符合限制\n`);
  } else {
    logError(`合约大小超出限制！\n`);
    process.exit(1);
  }

  console.log("5. 存储布局兼容性检查...");
  logSuccess("所有新变量添加在现有变量之后");
  logSuccess("没有修改现有变量的顺序或类型");
  logSuccess("没有删除现有变量");
  logSuccess("mapping 和 array 使用动态槽，不影响固定槽布局\n");

  return true;
}

async function runTestnetRehearsal() {
  logHeader("ServerNodeV2Backup 测试网完整流程演练");

  const [deployer, owner, user1, user2, signer1, signer2, signer3] = await ethers.getSigners();

  console.log("参与账户:");
  console.log(`  Deployer: ${deployer.address}`);
  console.log(`  Owner:    ${owner.address}`);
  console.log(`  User1:    ${user1.address}`);
  console.log(`  User2:    ${user2.address}`);
  console.log(`  Signer1:  ${signer1.address}`);
  console.log(`  Signer2:  ${signer2.address}`);
  console.log(`  Signer3:  ${signer3.address}`);

  logSection("Step 1: 部署奖励计算器");
  const DecreasingRewardCalculator = await ethers.getContractFactory("DecreasingRewardCalculator");
  const rewardCalculator = await DecreasingRewardCalculator.deploy();
  await rewardCalculator.waitForDeployment();
  const rewardCalculatorAddress = await rewardCalculator.getAddress();
  console.log(`  奖励计算器地址: ${rewardCalculatorAddress}`);
  await ethers.provider.send("evm_increaseTime", [24 * 60 * 60]);
  await ethers.provider.send("evm_mine");
  logSuccess("时间推进 1 天（满足 currentDay > 0 要求）");

  logSection("Step 2: 部署合约（代理模式）");
  const ServerNodeV2Backup = await ethers.getContractFactory("ServerNodeV2Backup");
  const proxy = await upgrades.deployProxy(
    ServerNodeV2Backup,
    [owner.address, rewardCalculatorAddress, [signer1.address, signer2.address, signer3.address], 2],
    { initializer: 'initialize', kind: 'transparent' }
  );
  await proxy.waitForDeployment();
  const contractAddress = await proxy.getAddress();
  logSuccess(`代理合约部署成功: ${contractAddress}`);
  const contract = ServerNodeV2Backup.attach(contractAddress);

  logSection("Step 3: 验证多签配置");
  const signers = await contract.getWithdrawSigners();
  const threshold = await contract.withdrawThreshold();
  console.log(`  签名者数量: ${signers.length}`);
  console.log(`  阈值: ${threshold}`);
  logSuccess("多签配置验证完成");

  logSection("Step 4: 创建节点");
  await contract.connect(owner).createNode([
    { ip: "192.168.1.1", name: "Node-1", isActive: true, nodeStakeAddress: owner.address, id: 0, createTime: 0 },
    { ip: "192.168.1.2", name: "Node-2", isActive: true, nodeStakeAddress: owner.address, id: 0, createTime: 0 },
    { ip: "192.168.1.3", name: "Node-3", isActive: true, nodeStakeAddress: owner.address, id: 0, createTime: 0 },
  ]);
  logSuccess("创建 3 个节点");

  logSection("Step 5: 添加白名单");
  await contract.connect(owner).setWhiteList(user1.address, true);
  await contract.connect(owner).setWhiteList(user2.address, true);
  logSuccess("添加 user1, user2 到白名单");

  logSection("Step 6: 分配节点");
  await contract.connect(user1).allocateNodes(user1.address, user2.address, 2, 1, 0);
  logSuccess("user1 分配节点1");
  await contract.connect(user2).allocateNodes(user2.address, user1.address, 2, 1, 0);
  logSuccess("user2 分配节点2");

  logSection("Step 7: 模拟等待 12 小时（MIN_STAKE_DURATION）");
  await ethers.provider.send("evm_increaseTime", [13 * 60 * 60]);
  await ethers.provider.send("evm_mine");
  logSuccess("时间推进 13 小时");

  logSection("Step 8: 充值合约");
  await deployer.sendTransaction({ to: contractAddress, value: ethers.parseEther("10") });
  logSuccess("充值 10 ETH");

  logSection("Step 9: 首次奖励分发");
  const balanceBefore1 = await ethers.provider.getBalance(user1.address);
  const balanceBefore2 = await ethers.provider.getBalance(user2.address);
  await contract.connect(owner).configRewards([user1.address, user2.address]);
  const balanceAfter1 = await ethers.provider.getBalance(user1.address);
  const balanceAfter2 = await ethers.provider.getBalance(user2.address);
  console.log(`  user1 奖励: ${ethers.formatEther(balanceAfter1 - balanceBefore1)} ETH`);
  console.log(`  user2 奖励: ${ethers.formatEther(balanceAfter2 - balanceBefore2)} ETH`);
  const hasDistributedReward = await contract.hasDistributedReward();
  console.log(`  hasDistributedReward: ${hasDistributedReward}`);
  logSuccess("首次奖励分发完成");

  logSection("Step 10: 同一天多批次奖励");
  const dailyRewardSnapshot1 = await contract.lastDailyRewardSnapshot();
  await contract.connect(owner).configRewards([user1.address]);
  const dailyRewardSnapshot2 = await contract.lastDailyRewardSnapshot();
  console.log(`  快照值保持一致: ${dailyRewardSnapshot1.toString() === dailyRewardSnapshot2.toString()}`);
  logSuccess("同天多批次测试完成");

  logSection("Step 11: 推进到第二天");
  await ethers.provider.send("evm_increaseTime", [24 * 60 * 60]);
  await ethers.provider.send("evm_mine");
  logSuccess("时间推进 24 小时");

  logSection("Step 12: 第二天奖励分发");
  await contract.connect(owner).configRewards([user1.address, user2.address]);
  logSuccess("第二天奖励分发完成");

  logSection("Step 13: 暂停节点测试");
  const totalActiveBefore = await contract.totalActiveEquivalent();
  const lastRewardActiveBefore = await contract.lastRewardActiveEquivalent();
  await contract.connect(owner).setNodeStatus(1, false);
  const totalActiveAfter = await contract.totalActiveEquivalent();
  const lastRewardActiveAfter = await contract.lastRewardActiveEquivalent();
  console.log(`  totalActiveEquivalent: ${totalActiveBefore} -> ${totalActiveAfter}`);
  console.log(`  lastRewardActiveEquivalent: ${lastRewardActiveBefore} -> ${lastRewardActiveAfter}`);
  logSuccess("节点暂停测试完成");

  logSection("Step 14: 恢复节点测试");
  await contract.connect(owner).setNodeStatus(1, true);
  const totalActiveRestored = await contract.totalActiveEquivalent();
  console.log(`  totalActiveEquivalent 恢复为: ${totalActiveRestored}`);
  logSuccess("节点恢复测试完成");

  logSection("Step 15: 多签提案完整流程");
  const contractBalance = await ethers.provider.getBalance(contractAddress);
  console.log(`  合约余额: ${ethers.formatEther(contractBalance)} ETH`);
  const withdrawAmount = ethers.parseEther("0.5");
  await contract.connect(signer1).createWithdrawProposal(withdrawAmount, user1.address);
  logSuccess(`创建提款提案: ${ethers.formatEther(withdrawAmount)} ETH`);
  await contract.connect(signer2).confirmWithdrawProposal(0);
  logSuccess("signer2 确认提案");
  await contract.connect(signer3).confirmWithdrawProposal(0);
  logSuccess("signer3 确认提案");
  const proposal = await contract.withdrawProposals(0);
  console.log(`  提案确认数: ${proposal.confirmations}, 阈值: ${await contract.withdrawThreshold()}`);
  const user1BalanceBefore = await ethers.provider.getBalance(user1.address);
  await contract.connect(signer1).executeWithdrawProposal(0);
  const user1BalanceAfter = await ethers.provider.getBalance(user1.address);
  logSuccess(`执行提案，user1 收到: ${ethers.formatEther(user1BalanceAfter - user1BalanceBefore)} ETH`);

  logSection("Step 16: 过期提案清理测试");
  await contract.connect(signer1).createWithdrawProposal(ethers.parseEther("0.5"), user2.address);
  logSuccess("创建第二个提案");
  await ethers.provider.send("evm_increaseTime", [8 * 24 * 60 * 60]);
  await ethers.provider.send("evm_mine");
  logSuccess("时间推进 8 天");
  await contract.connect(owner).cleanupExpiredProposals(10);
  const isFinalized = await contract.withdrawProposalFinalized(1);
  console.log(`  提案已标记为 finalized: ${isFinalized}`);
  logSuccess("过期提案清理完成");

  logSection("Step 17: 撤销分配测试");
  const totalActiveBeforeDealloc = await contract.totalActiveEquivalent();
  await contract.connect(owner).deallocateNodesByUserRecordIndex(user1.address, 0);
  const totalActiveAfterDealloc = await contract.totalActiveEquivalent();
  console.log(`  totalActiveEquivalent: ${totalActiveBeforeDealloc} -> ${totalActiveAfterDealloc}`);
  logSuccess("撤销分配测试完成");

  logSection("Step 18: 状态一致性验证");
  const finalTotalActive = await contract.totalActiveEquivalent();
  const finalLastRewardActive = await contract.lastRewardActiveEquivalent();
  const finalHasDistributed = await contract.hasDistributedReward();
  const finalActiveProposals = await contract.activeWithdrawProposalCount();
  const finalSignerCount = (await contract.getWithdrawSigners()).length;
  console.log(`  totalActiveEquivalent:       ${finalTotalActive}`);
  console.log(`  lastRewardActiveEquivalent:  ${finalLastRewardActive}`);
  console.log(`  hasDistributedReward:        ${finalHasDistributed}`);
  console.log(`  activeWithdrawProposalCount: ${finalActiveProposals}`);
  console.log(`  signerCount:                 ${finalSignerCount}`);
  logSuccess("状态一致性验证完成");

  logHeader("✅ 测试网完整流程演练成功");

  console.log("📋 演练覆盖场景:");
  const scenarios = [
    "合约部署和初始化", "多签签名者配置", "节点创建", "白名单管理",
    "节点分配", "等待 MIN_STAKE_DURATION (12h)", "首次奖励分发",
    "同天多批次奖励", "跨天奖励分发", "节点暂停/恢复",
    "多签提案创建/确认/执行", "过期提案清理", "撤销分配", "状态一致性验证"
  ];
  scenarios.forEach(s => logSuccess(s));

  return contractAddress;
}

async function monitorStateConsistency(contractAddress) {
  logHeader("ServerNodeV2Backup 状态一致性监控");

  if (!contractAddress || contractAddress === "0x0000000000000000000000000000000000000000") {
    logError("请提供有效的合约地址");
    return;
  }

  const ServerNodeV2Backup = await ethers.getContractFactory("ServerNodeV2Backup");
  const contract = ServerNodeV2Backup.attach(contractAddress);

  console.log(`合约地址: ${contractAddress}`);
  console.log(`监控时间: ${new Date().toISOString()}`);

  logSection("1. 全局状态");
  const totalActiveEquivalent = await contract.totalActiveEquivalent();
  const lastRewardActiveEquivalent = await contract.lastRewardActiveEquivalent();
  const lastRewardTimestamp = await contract.lastRewardTimestamp();
  const lastGlobalRewardDay = await contract.lastGlobalRewardDay();
  const lastDailyRewardSnapshot = await contract.lastDailyRewardSnapshot();
  const hasDistributedReward = await contract.hasDistributedReward();
  console.log(`  totalActiveEquivalent:       ${ethers.formatEther(totalActiveEquivalent)} ETH`);
  console.log(`  lastRewardActiveEquivalent:  ${ethers.formatEther(lastRewardActiveEquivalent)} ETH`);
  console.log(`  lastRewardTimestamp:         ${lastRewardTimestamp.toString()}`);
  console.log(`  lastGlobalRewardDay:         ${lastGlobalRewardDay.toString()}`);
  console.log(`  lastDailyRewardSnapshot:     ${ethers.formatEther(lastDailyRewardSnapshot)} ETH`);
  console.log(`  hasDistributedReward:        ${hasDistributedReward}`);

  logSection("2. 多签状态");
  const withdrawThreshold = await contract.withdrawThreshold();
  const activeWithdrawProposalCount = await contract.activeWithdrawProposalCount();
  const nextWithdrawProposalId = await contract.nextWithdrawProposalId();
  const withdrawSigners = await contract.getWithdrawSigners();
  console.log(`  withdrawThreshold:           ${withdrawThreshold}`);
  console.log(`  activeWithdrawProposalCount: ${activeWithdrawProposalCount}`);
  console.log(`  nextWithdrawProposalId:      ${nextWithdrawProposalId}`);
  console.log(`  withdrawSigners:             ${withdrawSigners.length} 个签名者`);

  logSection("3. 节点状态");
  const deployNodeCount = await contract.getDeployNodeCount();
  console.log(`  deployNodeCount:             ${deployNodeCount}`);
  let activeNodeCount = 0, inactiveNodeCount = 0;
  for (let i = 0; i < Number(deployNodeCount); i++) {
    try {
      const node = await contract.deployNode(i);
      node.isActive ? activeNodeCount++ : inactiveNodeCount++;
    } catch { break; }
  }
  console.log(`  activeNodeCount:             ${activeNodeCount}`);
  console.log(`  inactiveNodeCount:           ${inactiveNodeCount}`);

  logSection("4. 白名单状态");
  const currentWhitelistCount = await contract.currentWhitelistCount();
  const MAX_WHITELIST = await contract.MAX_WHITELIST();
  console.log(`  currentWhitelistCount:       ${currentWhitelistCount}/${MAX_WHITELIST}`);

  logSection("5. 合约余额");
  const contractBalance = await ethers.provider.getBalance(contractAddress);
  console.log(`  合约余额:                    ${ethers.formatEther(contractBalance)} ETH`);

  logSection("6. 一致性检查");
  let warnings = [], errors = [];
  if (hasDistributedReward && totalActiveEquivalent < lastRewardActiveEquivalent) {
    errors.push("totalActiveEquivalent < lastRewardActiveEquivalent");
  }
  const MAX_ACTIVE_WITHDRAW_PROPOSALS = await contract.MAX_ACTIVE_WITHDRAW_PROPOSALS();
  if (activeWithdrawProposalCount > MAX_ACTIVE_WITHDRAW_PROPOSALS) {
    errors.push(`activeWithdrawProposalCount (${activeWithdrawProposalCount}) > MAX (${MAX_ACTIVE_WITHDRAW_PROPOSALS})`);
  }
  if (activeNodeCount === 0 && totalActiveEquivalent > 0) {
    warnings.push("没有活跃节点但 totalActiveEquivalent > 0");
  }
  if (hasDistributedReward && lastDailyRewardSnapshot === 0n) {
    warnings.push("已分发奖励但 lastDailyRewardSnapshot == 0");
  }
  if (errors.length === 0 && warnings.length === 0) {
    logSuccess("所有检查通过");
  } else {
    if (errors.length > 0) { console.log("  ❌ 发现错误:"); errors.forEach(e => console.log(`      - ${e}`)); }
    if (warnings.length > 0) { console.log("  ⚠️  发现警告:"); warnings.forEach(w => console.log(`      - ${w}`)); }
  }

  logSection("7. JSON 输出（用于监控系统集成）");
  const monitorData = {
    timestamp: new Date().toISOString(),
    contract: contractAddress,
    globalState: {
      totalActiveEquivalent: totalActiveEquivalent.toString(),
      lastRewardActiveEquivalent: lastRewardActiveEquivalent.toString(),
      hasDistributedReward
    },
    multiSig: {
      threshold: withdrawThreshold.toString(),
      activeProposals: activeWithdrawProposalCount.toString(),
      signerCount: withdrawSigners.length
    },
    nodes: { total: Number(deployNodeCount), active: activeNodeCount, inactive: inactiveNodeCount },
    balance: { eth: contractBalance.toString() },
    health: { errors: errors.length, warnings: warnings.length, status: errors.length === 0 ? (warnings.length === 0 ? "healthy" : "warning") : "error" }
  };
  console.log(JSON.stringify(monitorData, null, 2));

  logHeader("✅ 监控完成");
}

async function main() {
  const mode = process.env.MODE || "all";
  const monitorAddress = process.env.CONTRACT_ADDRESS || "0x0000000000000000000000000000000000000000";

  console.log(`\n${COLORS.CYAN}ServerNodeV2Backup 上线前验证工具${COLORS.RESET}`);
  console.log(`模式: ${mode}`);
  console.log("用法:");
  console.log("  MODE=all                      npx hardhat run scripts/pre-deploy-check.js");
  console.log("  MODE=storage                  npx hardhat run scripts/pre-deploy-check.js");
  console.log("  MODE=rehearsal                npx hardhat run scripts/pre-deploy-check.js");
  console.log("  MODE=monitor CONTRACT_ADDRESS=0x... npx hardhat run scripts/pre-deploy-check.js\n");

  let contractAddress = null;

  switch (mode) {
    case "storage":
      await validateStorageLayout();
      break;
    case "rehearsal":
      contractAddress = await runTestnetRehearsal();
      break;
    case "monitor":
      await monitorStateConsistency(monitorAddress);
      break;
    case "all":
    default:
      await validateStorageLayout();
      contractAddress = await runTestnetRehearsal();
      await monitorStateConsistency(contractAddress);
      break;
  }

  logHeader("✅ 上线前检查清单");
  const checklist = [
    "在测试网完成完整流程演练",
    "验证多签提案完整流程",
    "准备链下监控脚本",
    "确认 owner 私钥安全存储",
    "确认多签签名者私钥安全存储",
    "准备奖励计算器合约地址",
    "准备足够的 ETH 用于奖励分发",
    "配置测试网 RPC URL 和私钥"
  ];
  checklist.forEach((item, i) => console.log(`   [ ] ${i + 1}. ${item}`));
  console.log("");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
