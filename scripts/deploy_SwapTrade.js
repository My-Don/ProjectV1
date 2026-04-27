require("dotenv").config();

const { ethers, upgrades } = require("hardhat");
const fs = require("fs");
const path = require("path");

/**
 * 大白话：
 * 这个脚本会先部署 3 个测试 ERC20：
 * 1. BKC
 * 2. SNC
 * 3. USDT
 *
 * 然后再部署 SwapTrade：
 * constructor(
 *   address _bkc,
 *   address _snc,
 *   address _usdt,
 *   address _uniswapV2Router
 * )
 *
 */

function getRequiredEnv(name) {
  const value = process.env[name];

  if (!value || value.trim() === "") {
    throw new Error(`缺少环境变量：${name}`);
  }

  return value.trim();
}

async function deployMockERC20(name, symbol) {
  console.log(`\n开始部署 ${symbol}...`);

  const ERC20 = await ethers.getContractFactory("MockERC20");

  // 大白话：这里要求你的 MockERC20 构造函数是 constructor(string name, string symbol)
  const token = await ERC20.deploy(name, symbol);

  await token.waitForDeployment();

  const tokenAddress = await token.getAddress();

  console.log(`✅ ${symbol} 部署成功:`, tokenAddress);

  // 大白话：简单读一下 ERC20 基本信息，确认合约正常
  const tokenName = await token.name();
  const tokenSymbol = await token.symbol();
  const totalSupply = await token.totalSupply();

  console.log(`${symbol} 名称:`, tokenName);
  console.log(`${symbol} 符号:`, tokenSymbol);
  console.log(`${symbol} 总供应量:`, ethers.formatEther(totalSupply));

  return {
    contract: token,
    address: tokenAddress,
  };
}

async function main() {
  const [deployer] = await ethers.getSigners();

  console.log("========================================");
  console.log("使用账户地址部署:", deployer.address);

  const network = await ethers.provider.getNetwork();
  console.log("当前网络 Chain ID:", network.chainId.toString());

  const balance = await ethers.provider.getBalance(deployer.address);
  console.log("部署账户余额:", ethers.formatEther(balance));

  if (balance === 0n) {
    throw new Error("部署账户余额为 0，无法支付 gas");
  }

  console.log("========================================");

  /**
   * 第一步：部署三个测试 token
   */
  const bkc = await deployMockERC20("BKC Token", "BKC");
  const snc = await deployMockERC20("SNC Token", "SNC");
  const usdt = await deployMockERC20("USDT Token", "USDT");

  const bkcAddress = bkc.address;
  const sncAddress = snc.address;
  const usdtAddress = usdt.address;

  /**
   * 第二步：读取 Router 地址
   *
   * 大白话：
   * SwapTrade 构造函数里会调用 router.factory()
   * 所以这个地址必须是真正的 UniswapV2Router / PancakeRouter 这类路由器地址。
   *
   * 如果你只是随便填一个地址，SwapTrade 部署会失败。
   */
  const routerAddress = ethers.getAddress(getRequiredEnv("UNISWAP_V2_ROUTER"));

  console.log("\n准备部署 SwapTrade...");
  console.log("BKC 地址:", bkcAddress);
  console.log("SNC 地址:", sncAddress);
  console.log("USDT 地址:", usdtAddress);
  console.log("Router 地址:", routerAddress);

  // 大白话：检查 Router 地址上是不是有合约代码
  const routerCode = await ethers.provider.getCode(routerAddress);

  if (routerCode === "0x") {
    throw new Error(`Router 地址上没有合约代码，请检查 UNISWAP_V2_ROUTER: ${routerAddress}`);
  }

  /**
   * 第三步：部署 SwapTrade
   */
  const SwapTrade = await ethers.getContractFactory("SwapTrade");

  const swapTrade = await SwapTrade.deploy(
    bkcAddress,
    sncAddress,
    usdtAddress,
    routerAddress
  );

  await swapTrade.waitForDeployment();

  const swapTradeAddress = await swapTrade.getAddress();

  console.log("\n✅ SwapTrade 部署成功:", swapTradeAddress);

  /**
   * 第四步：部署后验证
   */
  const owner = await swapTrade.owner();
  const contractBkc = await swapTrade.bkc();
  const contractSnc = await swapTrade.snc();
  const contractUsdt = await swapTrade.usdt();
  const contractRouter = await swapTrade.uniswapV2Router();
  const contractFactory = await swapTrade.factory();

  console.log("\n初始化验证:");
  console.log("Owner:", owner);
  console.log("BKC:", contractBkc);
  console.log("SNC:", contractSnc);
  console.log("USDT:", contractUsdt);
  console.log("Router:", contractRouter);
  console.log("Factory:", contractFactory);

  /**
   * 第五步：保存部署结果
   */
  const deploymentTx = swapTrade.deploymentTransaction();

  const deploymentInfo = {
    network: hreNetworkName(),
    chainId: network.chainId.toString(),
    deployer: deployer.address,

    contracts: {
      BKC: bkcAddress,
      SNC: sncAddress,
      USDT: usdtAddress,
      SwapTrade: swapTradeAddress,
    },

    swapTrade: {
      owner,
      bkc: contractBkc,
      snc: contractSnc,
      usdt: contractUsdt,
      router: contractRouter,
      factory: contractFactory,
    },

    txHash: deploymentTx ? deploymentTx.hash : null,
    deployedAt: new Date().toISOString(),
  };

  const outputDir = path.join(process.cwd(), "deployments", hreNetworkName());
  const outputFile = path.join(outputDir, "SwapTrade.json");

  fs.mkdirSync(outputDir, { recursive: true });
  fs.writeFileSync(outputFile, JSON.stringify(deploymentInfo, null, 2));

  console.log("\n部署信息已保存到:", outputFile);

  console.log("\n========================================");
  console.log("全部部署完成");
  console.log("BKC:", bkcAddress);
  console.log("SNC:", sncAddress);
  console.log("USDT:", usdtAddress);
  console.log("SwapTrade:", swapTradeAddress);
  console.log("========================================");
}

function hreNetworkName() {
  // 大白话：为了少引一个 hre，这里直接从 hardhat 运行环境里取网络名
  return require("hardhat").network.name;
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("\n❌ 部署失败:");
    console.error(error);
    process.exit(1);
  });
