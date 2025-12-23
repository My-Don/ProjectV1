// scripts/deployUniswapV2Factory.js
const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  console.log("Deploying contracts with the account:", deployer.address);

  // 部署路由合约
  const UniswapV2Router02 = await hre.ethers.getContractFactory("UniswapV2Router02");
  const router = await UniswapV2Router02.deploy("0x15e51143e4F963f719cEc4a99a951bA9C63860c5", "0x5e6031572A58f02cd73b3bB5523365D77D1Bb1F4");
  
  // 等待部署完成
  await router.waitForDeployment();
  
  // 获取合约地址
  const routerAddress = await router.getAddress();
  console.log("UniswapV2Router02 deployed to:", routerAddress);

  return routerAddress;
}

main()
  .then((address) => {
    console.log("Deployment completed. UniswapV2Router02 address:", address);
    process.exit(0);
  })
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });