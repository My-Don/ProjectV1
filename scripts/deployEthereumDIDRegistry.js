const { ethers, upgrades} = require("hardhat");


async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("使用账户地址部署:", deployer.address);


  // 部署EthereumDIDRegistry合约
  const EthereumDIDRegistry = await ethers.getContractFactory("EthereumDIDRegistry");
  const ethereumDIDRegistry = await EthereumDIDRegistry.deploy();
  await ethereumDIDRegistry.waitForDeployment();

  const ethereumDIDRegistryAddress = await ethereumDIDRegistry.getAddress();
  console.log("✅EthereumDIDRegistry 部署成功:", ethereumDIDRegistryAddress);

 
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });