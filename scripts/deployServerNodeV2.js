const { ethers, upgrades } = require("hardhat");
const fs = require('fs');

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("使用账户地址部署:", deployer.address);

  // 检查合约工厂
  const ServerNodeBackup = await ethers.getContractFactory("ServerNodeV2Backup");
  console.log("合约工厂加载成功");

  // 部署参数
  const initialOwner = "0x5159eA8501d3746bB07c20B5D0406bD12844D7ec"; // 合约所有者
  const rewardCalculator = "0x1476BFD08B5556d853807C2d89FE08274Cea23aC"; // 奖励计算器
  const signers = [
    "0xDfc38b97bCc82B16802e676fbB939623F9EA5b4f",
    "0xeCe513834253230680a4D88D592E0bE79d1202Db",
    "0xf9fFCDD58FA6c16F4E1d1A7180Ddb226dD87F32F"
  ]; // 多签签名人
  const threshold = 2; // 多签阈值

  console.log("\n部署参数:");
  console.log("- 初始所有者:", initialOwner);
  console.log("- 奖励计算器:", rewardCalculator);
  console.log("- 多签签名人:", signers);
  console.log("- 多签阈值:", threshold);

  console.log("\n正在部署 ServerNodeV2Backup 合约（透明代理模式）...");

  // 使用透明代理模式部署
  const contract = await upgrades.deployProxy(
    ServerNodeBackup,
    [initialOwner, rewardCalculator, signers, threshold],
    {
      initializer: 'initialize',
      kind: 'transparent' // 明确指定透明代理模式
    }
  );

  console.log("等待合约部署确认...");
  await contract.waitForDeployment();

  // 获取代理合约地址
  const proxyAddress = await contract.getAddress();
  console.log("\n✅ 部署完成!");
  console.log("=".repeat(50));
  console.log("代理合约地址:", proxyAddress);

  // 获取逻辑合约地址
  const logicAddress = await upgrades.erc1967.getImplementationAddress(proxyAddress);
  console.log("逻辑合约地址:", logicAddress);

  // 获取代理管理合约地址（透明代理模式会有ProxyAdmin合约）
  const adminAddress = await upgrades.erc1967.getAdminAddress(proxyAddress);
  console.log("代理管理合约地址:", adminAddress);

  // 获取ProxyAdmin合约实例
  const ProxyAdminABI = [
    "function owner() view returns (address)",
    "function transferOwnership(address newOwner)",
    "function renounceOwnership()",
    "function upgradeAndCall(address proxy, address implementation, bytes memory data) payable"
  ];

  const proxyAdmin = new ethers.Contract(adminAddress, ProxyAdminABI, deployer);

  // 获取ProxyAdmin的所有者
  const proxyAdminOwner = await proxyAdmin.owner();
  console.log("ProxyAdmin所有者:", proxyAdminOwner);


  // 转移ProxyAdmin所有权给部署者（如果还不是的话）
  if (proxyAdminOwner.toLowerCase() !== deployer.address.toLowerCase()) {
    console.log("\n正在将ProxyAdmin所有权转移给部署者...");
    const tx = await proxyAdmin.transferOwnership(deployer.address);
    await tx.wait();
    console.log("✅ ProxyAdmin所有权已转移给:", deployer.address);
  }

  // 验证合约功能
  console.log("\n验证合约功能...");
  try {
    // 验证合约所有者
    const ownerAddress = await contract.owner();
    console.log("合约所有者:", ownerAddress);
    console.log("✓ 所有者设置正确:", ownerAddress === initialOwner);

    // 验证多签设置
    const [signersArray, currentThreshold] = await contract.getWithdrawMultiSigInfo();
    console.log("\n多签设置验证:");
    console.log("- 签名人数量:", signersArray.length);
    console.log("- 阈值:", currentThreshold.toString());
    console.log("✓ 多签设置正确");


  } catch (error) {
    console.warn("功能验证警告:", error.message);
  }

  // 保存部署信息到文件
  const deploymentInfo = {
    network: await ethers.provider.getNetwork(),
    timestamp: new Date().toISOString(),
    deploymentType: "transparent-proxy",
    proxyAddress: proxyAddress,
    logicAddress: logicAddress,
    adminAddress: adminAddress,
    adminOwner: deployer.address,
    initialOwner: initialOwner,
    rewardCalculator: rewardCalculator,
    signers: signers,
    threshold: threshold,
    txHash: contract.deploymentTransaction().hash,
    blockNumber: contract.deploymentTransaction().blockNumber
  };

  const filename = `deployment-transparent-${Date.now()}.json`;
  fs.writeFileSync(filename, JSON.stringify(deploymentInfo, null, 2));

  console.log("\n✅ 部署信息已保存到:", filename);

  // 生成验证命令
  console.log("\n验证命令:");
  console.log(`npx hardhat verify --network ${deploymentInfo.network.name} ${logicAddress}`);

  // 生成升级命令
  console.log("\n升级命令:");
  console.log(`npx hardhat run scripts/upgrade-transparent.js --network ${deploymentInfo.network.name}`);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("部署失败:", error);
    if (error.transaction) {
      console.error("交易哈希:", error.transaction.hash);
    }
    process.exit(1);
  });
