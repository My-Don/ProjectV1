const { ethers } = require("hardhat");
const fs = require("fs");
require("dotenv").config();

function requireEnv(name) {
  const value = process.env[name];

  if (!value || value.trim() === "") {
    throw new Error(`缺少环境变量: ${name}`);
  }

  return value.trim();
}

function checkAddress(name, value) {
  if (!ethers.isAddress(value)) {
    throw new Error(`${name} 不是合法地址: ${value}`);
  }
}

async function main() {
  const [deployer] = await ethers.getSigners();

  console.log("使用账户地址部署:", deployer.address);

  // =========================
  // 读取部署参数
  // =========================

  const usdtAddress = requireEnv("USDT_ADDRESS");
  const gbcAddress = requireEnv("GBC_ADDRESS");

  // OWNER_ADDRESS 不填时，默认用部署者地址
  const ownerAddress =
    process.env.OWNER_ADDRESS && process.env.OWNER_ADDRESS.trim() !== ""
      ? process.env.OWNER_ADDRESS.trim()
      : deployer.address;

  checkAddress("USDT_ADDRESS", usdtAddress);
  checkAddress("GBC_ADDRESS", gbcAddress);
  checkAddress("OWNER_ADDRESS", ownerAddress);

  console.log("\n部署参数:");
  console.log("=".repeat(50));
  console.log("USDT质押币地址:", usdtAddress);
  console.log("GBC奖励币地址:", gbcAddress);
  console.log("合约Owner地址:", ownerAddress);

  // =========================
  // 加载合约工厂
  // =========================

  // 如果你的文件名是 contracts/StakeMint.sol，用下面这个
  const StakeMint = await ethers.getContractFactory(
    "contracts/StakeMint.sol:StakeMint"
  );

  // 如果你的文件名是 contracts/StakeMint.final.v1.0.0.sol，
  // 就把上面一行改成：
  // const StakeMint = await ethers.getContractFactory(
  //   "contracts/StakeMint.final.v1.0.0.sol:StakeMint"
  // );

  console.log("\n合约工厂加载成功");

  // =========================
  // 部署 StakeMint
  // =========================

  console.log("\n正在部署 StakeMint 合约...");

  const stakeMint = await StakeMint.deploy(
    usdtAddress,
    gbcAddress,
    ownerAddress
  );

  console.log("等待合约部署确认...");
  await stakeMint.waitForDeployment();

  const stakeMintAddress = await stakeMint.getAddress();

  console.log("\n✅ StakeMint 部署完成!");
  console.log("=".repeat(50));
  console.log("StakeMint合约地址:", stakeMintAddress);

  // =========================
  // 读取合约关键参数
  // =========================

  console.log("\n读取合约配置...");
  console.log("=".repeat(50));

  const contractVersion = await stakeMint.CONTRACT_VERSION();
  const stakeUnit = await stakeMint.STAKE_UNIT();
  const gbcDecimals = await stakeMint.GBC_DECIMALS();
  const hashRate = await stakeMint.HASHRATE();
  const basicPower = await stakeMint.BASICCOMPUTINGPOWER();
  const timeInterval = await stakeMint.TIMEINTERVAL();
  const updateInterval = await stakeMint.UPDATE_INTERVAL();
  const maxHistoryLength = await stakeMint.MAX_HISTORY_LENGTH();

  console.log("合约版本:", contractVersion);
  console.log("STAKE_UNIT:", stakeUnit.toString());
  console.log("GBC_DECIMALS:", gbcDecimals.toString());
  console.log("HASHRATE:", hashRate.toString());
  console.log("BASICCOMPUTINGPOWER:", basicPower.toString());
  console.log("TIMEINTERVAL:", timeInterval.toString());
  console.log("UPDATE_INTERVAL:", updateInterval.toString());
  console.log("MAX_HISTORY_LENGTH:", maxHistoryLength.toString());

  // =========================
  // 验证合约基础功能
  // =========================

  console.log("\n验证合约功能...");
  console.log("=".repeat(50));

  try {
    const realOwner = await stakeMint.owner();
    const realUSDT = await stakeMint.USDT();
    const realGBC = await stakeMint.GBC();

    console.log("合约Owner:", realOwner);
    console.log("USDT地址:", realUSDT);
    console.log("GBC地址:", realGBC);

    console.log(
      "✓ Owner设置正确:",
      realOwner.toLowerCase() === ownerAddress.toLowerCase()
    );

    console.log(
      "✓ USDT设置正确:",
      realUSDT.toLowerCase() === usdtAddress.toLowerCase()
    );

    console.log(
      "✓ GBC设置正确:",
      realGBC.toLowerCase() === gbcAddress.toLowerCase()
    );
  } catch (error) {
    console.warn("功能验证警告:", error.message);
  }

  // =========================
  // 保存部署信息
  // =========================

  const network = await ethers.provider.getNetwork();

  const deploymentInfo = {
    network: {
      name: network.name,
      chainId: network.chainId.toString(),
    },
    deployer: deployer.address,
    stakeMint: stakeMintAddress,
    usdt: usdtAddress,
    gbc: gbcAddress,
    owner: ownerAddress,
    contractVersion,
    stakeUnit: stakeUnit.toString(),
    gbcDecimals: gbcDecimals.toString(),
    hashRate: hashRate.toString(),
    basicComputingPower: basicPower.toString(),
    timeInterval: timeInterval.toString(),
    updateInterval: updateInterval.toString(),
    maxHistoryLength: maxHistoryLength.toString(),
    deployedAt: new Date().toISOString(),
    constructorArgs: [usdtAddress, gbcAddress, ownerAddress],
  };

  if (!fs.existsSync("deployments")) {
    fs.mkdirSync("deployments");
  }

  const fileName = `deployments/StakeMint-${network.chainId.toString()}.json`;

  fs.writeFileSync(fileName, JSON.stringify(deploymentInfo, null, 2));

  console.log("\n部署信息已保存:", fileName);

  // =========================
  // 浏览器验证参数
  // =========================

  console.log("\n合约验证参数:");
  console.log("=".repeat(50));
  console.log(
    JSON.stringify([usdtAddress, gbcAddress, ownerAddress], null, 2)
  );

  console.log("\n✅ 全部完成!");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("部署失败:", error);

    if (error.transaction) {
      console.error("交易哈希:", error.transaction.hash);
    }

    process.exit(1);
  });
