const { ethers, upgrades} = require("hardhat");


async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("使用账户地址部署:", deployer.address);


  // 先部署一个erc20合约
  const ERC20 = await ethers.getContractFactory("MockERC20");
  const erc20 = await ERC20.deploy("BKC Token", "BKC");
  await erc20.waitForDeployment();

  const erc20Address = await erc20.getAddress();
  console.log("✅ BKC 部署成功:", erc20Address);

  // 验证初始化
//   const contractName = await contract.name();
//   const contractSymbol = await contract.symbol();
//   const contractTotalSupply = await contract.totalSupply();

//   console.log("\n初始化验证:");
//   console.log("合约名称:", contractName);
//   console.log("合约符号:", contractSymbol);
//   console.log("总供应量:", ethers.formatEther(contractTotalSupply));

  // 等待几个区块确认
  console.log("\n等待区块确认...");

}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });