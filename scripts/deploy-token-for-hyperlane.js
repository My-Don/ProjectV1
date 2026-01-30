// 用于 Hyperlane 跨链桥接的 ERC20 Token 部署脚本
const hre = require("hardhat");

async function main() {
  console.log("开始部署 ERC20 Token 用于 Hyperlane 跨链桥接...\n");

  // 获取部署者账户
  const [deployer] = await hre.ethers.getSigners();
  console.log("部署账户:", deployer.address);
  console.log("账户余额:", hre.ethers.formatEther(await hre.ethers.provider.getBalance(deployer.address)), "ETH\n");

  // 选择要部署的合约类型
  // 方案 1: MockERC20 (推荐用于测试，功能丰富)
  console.log("部署 MockERC20...");
  const MockERC20 = await hre.ethers.getContractFactory("MockERC20");
  const mockToken = await MockERC20.deploy(
    "My Cross-Chain Token",  // Token 名称
    "MCCT"                   // Token 符号
  );
  await mockToken.waitForDeployment();
  const mockTokenAddress = await mockToken.getAddress();
  console.log("✅ MockERC20 部署成功!");
  console.log("   地址:", mockTokenAddress);
  console.log("   名称:", await mockToken.name());
  console.log("   符号:", await mockToken.symbol());
  console.log("   精度:", await mockToken.decimals());
  console.log("   初始供应量:", hre.ethers.formatEther(await mockToken.totalSupply()), "tokens");
  console.log("   部署者余额:", hre.ethers.formatEther(await mockToken.balanceOf(deployer.address)), "tokens\n");

  // 方案 2: USDT (稳定币实现)
  // console.log("部署 USDT...");
  // const USDT = await hre.ethers.getContractFactory("USDT");
  // const usdt = await USDT.deploy();
  // await usdt.waitForDeployment();
  // const usdtAddress = await usdt.getAddress();
  // console.log("✅ USDT 部署成功!");
  // console.log("   地址:", usdtAddress);
  // console.log("   名称:", await usdt.name());
  // console.log("   符号:", await usdt.symbol());
  // console.log("   精度:", await usdt.decimals());
  // console.log("   初始供应量:", hre.ethers.formatEther(await usdt.totalSupply()), "tokens\n");

  // 方案 3: WETH (包装 ETH)
  // console.log("部署 WETH9...");
  // const WETH = await hre.ethers.getContractFactory("WETH9");
  // const weth = await WETH.deploy();
  // await weth.waitForDeployment();
  // const wethAddress = await weth.getAddress();
  // console.log("✅ WETH9 部署成功!");
  // console.log("   地址:", wethAddress);
  // console.log("   名称:", await weth.name());
  // console.log("   符号:", await weth.symbol());
  // console.log("   精度:", await weth.decimals());
  // console.log("   总供应量:", hre.ethers.formatEther(await weth.totalSupply()), "tokens\n");

  console.log("=".repeat(80));
  console.log("部署完成！请保存以下信息用于 Hyperlane Warp Route 配置：");
  console.log("=".repeat(80));
  console.log("\n📋 Token 合约信息：");
  console.log("   合约地址:", mockTokenAddress);
  console.log("   网络:", hre.network.name);
  console.log("   Chain ID:", (await hre.ethers.provider.getNetwork()).chainId);
  console.log("\n📝 下一步操作：");
  console.log("   1. 记录上述 Token 合约地址");
  console.log("   2. 运行: hyperlane warp init");
  console.log("   3. 在配置中选择 'collateral' 类型");
  console.log("   4. 输入上述 Token 合约地址");
  console.log("   5. 运行: hyperlane warp deploy");
  console.log("\n💡 提示：");
  console.log("   - 确保在目标链上也有足够的 Gas 费用");
  console.log("   - 部署 Warp Route 后需要授权 Token 才能进行跨链转账");
  console.log("=".repeat(80));
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
