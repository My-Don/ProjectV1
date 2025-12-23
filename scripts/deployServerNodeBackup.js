const { ethers, upgrades} = require("hardhat");

// ProxyAdmin 合约的 ABI
const ProxyAdminABI = [
  "function owner() view returns (address)",
  "function transferOwnership(address newOwner)",
  "function getProxyAdmin(address proxy) view returns (address)"
];

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("使用账户地址部署:", deployer.address);


  // 使用完全限定名称部署可升级合约
  const ServerNodeBackup = await ethers.getContractFactory("ServerNodeBackup");


  console.log("正在部署 ServerNodeBackup 合约...");
  const contract = await upgrades.deployProxy(ServerNodeBackup, ["0x5159eA8501d3746bB07c20B5D0406bD12844D7ec", "0x3103b1b5a9f673e1674a9c0c3cBd5e07029492B9", "0x10Cd98b7DDaB859754AB67dD26fb3110609cCD03", ["0x5159eA8501d3746bB07c20B5D0406bD12844D7ec","0xDfc38b97bCc82B16802e676fbB939623F9EA5b4f","0xeCe513834253230680a4D88D592E0bE79d1202Db","0xf9fFCDD58FA6c16F4E1d1A7180Ddb226dD87F32F"], 2], {
    initializer: 'initialize',
  });
  await contract.waitForDeployment();

  // 获取代理合约地址
  const proxyAddress = await contract.getAddress();
  console.log("代理合约地址:", proxyAddress);

  // 获取逻辑合约地址
  const logicAddress = await upgrades.erc1967.getImplementationAddress(proxyAddress);
  console.log("逻辑合约地址:", logicAddress);

  // 获取代理管理合约地址
  const adminAddress = await upgrades.erc1967.getAdminAddress(proxyAddress);
  console.log("代理管理合约地址:", adminAddress);

  // 获取代理管理员地址
  const proxyAdmin = new ethers.Contract(adminAddress, ProxyAdminABI, deployer);
  const proxyAdminOwner = await proxyAdmin.owner();
  console.log("代理管理员地址:", proxyAdminOwner);

  // 如果代理管理员不是部署者，则转移管理员权限
  if (proxyAdminOwner.toLowerCase() !== deployer.address.toLowerCase()) {
    console.log("正在将代理管理员权限转移给部署者...");
    await proxyAdmin.transferOwnership(deployer.address);
    console.log("代理管理员权限已转移给:", deployer.address);
  }


}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
