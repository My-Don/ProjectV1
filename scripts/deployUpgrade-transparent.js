const { ethers, upgrades } = require("hardhat");
const fs = require('fs');
const path = require('path');

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("使用账户升级:", deployer.address);
    console.log("账户余额:", (await ethers.provider.getBalance(deployer.address)).toString(), "wei");

  // 已部署的代理合约地址
  const proxyAddress = "0x0D5Aa06365ddA6ea31743c01245817C64b9eCea8"; 

  const ServerNodeV2BackupV2 = await ethers.getContractFactory("ServerNodeV2Backup");
  
  // 部署新的逻辑合约
  console.log("部署新的逻辑合约...");
  const newImplementation = await ServerNodeV2BackupV2.deploy();
  await newImplementation.waitForDeployment();
  const newImplementationAddress = await newImplementation.getAddress();
  
  console.log("✅ 新逻辑合约部署完成");
  console.log("新逻辑合约地址:", newImplementationAddress);


let callData = "0x"; // 默认空数据

  // 4. 准备 upgradeAndCall 数据
  console.log("\n📝 准备升级数据...");


  // 5. 使用 upgradeAndCall 升级合约
  console.log("\n🔄 使用 upgradeAndCall 升级合约...");
  console.log("代理地址:", proxyAddress);
  console.log("新实现地址:", newImplementationAddress);
  console.log("调用数据:", callData || "0x");


  // 获取 ProxyAdmin 合约实例
  const proxyAdminAddress = await upgrades.erc1967.getAdminAddress(proxyAddress);
  const ProxyAdminABI = [
    "function upgradeAndCall(address proxy, address implementation, bytes data) public",
  ];
  const proxyAdmin = new ethers.Contract(proxyAdminAddress, ProxyAdminABI, deployer);

  try {
    // 估算 gas
    const estimatedGas = await proxyAdmin.upgradeAndCall.estimateGas(
      proxyAddress,
      newImplementationAddress,
      callData
    );
    console.log("估算Gas:", estimatedGas.toString());

    // 执行升级
    console.log("发送升级交易...");
    const tx = await proxyAdmin.upgradeAndCall(
      proxyAddress,
      newImplementationAddress,
      callData,
      {
        gasLimit: estimatedGas * 2n, // 安全起见，使用2倍估算值
      }
    );

    console.log("交易哈希:", tx.hash);
    console.log("等待交易确认...");

    const receipt = await tx.wait();
    console.log("✅ 升级交易已确认!");
    console.log("区块:", receipt.blockNumber);
    console.log("Gas使用量:", receipt.gasUsed.toString());
  }catch (error) {
    console.error("❌ 升级失败:", error.message);
    if (error.transaction) {
      console.error("交易哈希:", error.transaction.hash);
    }
    if (error.data) {
      console.error("错误数据:", error.data);
    }
    process.exit(1);
  }
  
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("脚本执行失败:", error);
    process.exit(1);
  });
