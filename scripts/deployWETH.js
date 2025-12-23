const { ethers, upgrades} = require("hardhat");


async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("使用账户地址部署:", deployer.address);

  // 先部署一个WETH合约
  const WETH = await ethers.getContractFactory("WETH9");
  const weth = await WETH.deploy();
  await weth.waitForDeployment();

  const wethAddress = await weth.getAddress();
  console.log("✅ WETH 部署成功:", wethAddress);

}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });