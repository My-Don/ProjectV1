const { ethers, upgrades } = require("hardhat");
const fs = require('fs');

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("使用账户地址部署:", deployer.address);

  // 检查合约工厂
  const USDC = await ethers.getContractFactory("contracts/USDC.sol:BEP20TokenImplementation");
  console.log("合约工厂加载成功");

  // 部署参数
  const name = "USD Coin"; 
  const symbol = "USDC"; 
  const decimals = 18;
  const amount = ethers.parseEther("8888"); 
  const mintable = false;
  const owner = deployer.address;


  console.log("\n正在部署 USDC 合约（透明代理模式）...");

  // 使用透明代理模式部署
  const contract = await upgrades.deployProxy(
    USDC,
    [name, symbol, decimals, amount, mintable, owner],
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

  } catch (error) {
    console.warn("功能验证警告:", error.message);
  }

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