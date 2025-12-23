const { ethers, upgrades} = require("hardhat");


async function main() {
  const [deployer] = await ethers.getSigners();
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