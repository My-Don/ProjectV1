const { ethers, upgrades} = require("hardhat");


async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("使用账户地址部署:", deployer.address);

  // 先部署一个usdt合约
  const BEPUSDT = await ethers.getContractFactory("USDT");
  const bepUsdt = await BEPUSDT.deploy();
  await bepUsdt.waitForDeployment();

  const bepUsdtAddress = await bepUsdt.getAddress();
  console.log("✅ BEPUSDT 部署成功:", bepUsdtAddress);

}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });