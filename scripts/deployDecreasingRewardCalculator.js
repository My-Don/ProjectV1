const { ethers } = require("hardhat");



async function main() {
  const signers = await ethers.getSigners();
  if (!signers.length) {
    throw new Error("未检测到部署账户，请在 .env 设置 PRIVATE_KEY（支持 0x 开头或 64 位私钥）并确认网络配置。");
  }
  const [deployer] = signers;
  console.log("使用账户地址部署:", deployer.address);



  // 部署DecreasingRewardCalculator合约
  const DecreasingRewardCalculator = await ethers.getContractFactory("DecreasingRewardCalculator");
  const decreasingRewardCalculator = await DecreasingRewardCalculator.deploy();
  await decreasingRewardCalculator.waitForDeployment();

  const decreasingRewardCalculatorAddress = await decreasingRewardCalculator.getAddress();
  console.log("✅ DecreasingRewardCalculator 部署成功:", decreasingRewardCalculatorAddress);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
