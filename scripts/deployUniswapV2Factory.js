// scripts/deployUniswapV2Factory.js
const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  console.log("Deploying contracts with the account:", deployer.address);

  // 部署工厂合约
  const UniswapV2Factory = await hre.ethers.getContractFactory("UniswapV2Factory");
  const factory = await UniswapV2Factory.deploy(deployer.address);
  
  // 等待部署完成
  await factory.waitForDeployment();
  
  // 获取合约地址
  const factoryAddress = await factory.getAddress();
  console.log("UniswapV2Factory deployed to:", factoryAddress);
  
  return factoryAddress;
}

main()
  .then((address) => {
    console.log("Deployment completed. Factory address:", address);
    process.exit(0);
  })
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });