/* eslint-disable no-console */

const hre = require("hardhat");
const { ethers } = hre;
const fs = require("fs");
const path = require("path");

/**
 * 这个脚本用于部署 My4337SmartAccountFactory。
 *
 * 注意：
 * - My4337SmartAccountFactory 不是透明代理合约。
 * - 不需要 upgrades.deployProxy。
 * - 不需要 ProxyAdmin。
 * - Factory 构造函数里会自动部署 My4337SmartAccount implementation。
 * - 每个用户账户后续通过 EIP-1167 clone + CREATE2 创建。
 */

function getContractAddress(contract) {
  // ethers v6
  if (contract.target) {
    return contract.target;
  }

  // ethers v5 兼容
  if (contract.address) {
    return contract.address;
  }

  throw new Error("无法读取合约地址，请检查 ethers / hardhat-ethers 版本");
}

function isAddress(address) {
  if (typeof ethers.isAddress === "function") {
    return ethers.isAddress(address);
  }

  return ethers.utils.isAddress(address);
}

function formatEther(value) {
  if (typeof ethers.formatEther === "function") {
    return ethers.formatEther(value);
  }

  return ethers.utils.formatEther(value);
}

function mustBeBytes32(value, name) {
  if (!/^0x[0-9a-fA-F]{64}$/.test(value)) {
    throw new Error(
      `${name} 必须是 bytes32 格式，例如：0x 后面跟 64 个十六进制字符`
    );
  }
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function tryVerify({ address, constructorArguments, contract }) {
  try {
    console.log(`\n正在验证合约: ${address}`);

    await hre.run("verify:verify", {
      address,
      constructorArguments,
      contract,
    });

    console.log(`✅ 验证成功: ${address}`);
  } catch (error) {
    const message = error && error.message ? error.message : String(error);

    if (
      message.toLowerCase().includes("already verified") ||
      message.toLowerCase().includes("already been verified")
    ) {
      console.log(`✅ 合约已经验证过: ${address}`);
      return;
    }

    console.warn(`⚠️ 验证失败: ${address}`);
    console.warn(message);
  }
}

async function main() {
  const [deployer] = await ethers.getSigners();

  console.log("使用账户地址部署:", deployer.address);

  const network = await ethers.provider.getNetwork();
  const deployerBalance = await ethers.provider.getBalance(deployer.address);

  console.log("网络名称:", hre.network.name);
  console.log("Chain ID:", network.chainId.toString());
  console.log("部署账户余额:", formatEther(deployerBalance), "ETH");

  /**
   * EntryPoint 地址必须从环境变量读取。
   *
   * 大白话：
   * - Factory 会绑定这个 EntryPoint。
   * - 后续账户的 validateUserOp 只信任这个 EntryPoint。
   * - 这个地址必须和你 bundler 使用的 EntryPoint 地址一致。
   */
  const entryPointAddress = process.env.ENTRYPOINT_ADDRESS;

  if (!entryPointAddress) {
    throw new Error(
      [
        "缺少 ENTRYPOINT_ADDRESS。",
        "示例：",
        "ENTRYPOINT_ADDRESS=0x你的EntryPoint地址 npx hardhat run scripts/deployMy4337SmartAccount.js --network sepolia",
      ].join("\n")
    );
  }

  if (!isAddress(entryPointAddress)) {
    throw new Error(`ENTRYPOINT_ADDRESS 不是合法地址: ${entryPointAddress}`);
  }

  /**
   * 可选：用于预计算 / 创建某个用户智能账户。
   *
   * OWNER_ADDRESS 不传时，默认使用 deployer.address。
   * SALT_HEX 不传时，默认使用 0。
   */
  const ownerAddress = process.env.OWNER_ADDRESS || deployer.address;

  if (!isAddress(ownerAddress)) {
    throw new Error(`OWNER_ADDRESS 不是合法地址: ${ownerAddress}`);
  }

  const saltHex =
    process.env.SALT_HEX ||
    "0x0000000000000000000000000000000000000000000000000000000000000000";

  mustBeBytes32(saltHex, "SALT_HEX");

  console.log("\n部署参数:");
  console.log("=".repeat(60));
  console.log("EntryPoint:", entryPointAddress);
  console.log("默认账户 Owner:", ownerAddress);
  console.log("默认账户 Salt:", saltHex);
  console.log("=".repeat(60));

  console.log("\n检查合约工厂...");

  const Factory = await ethers.getContractFactory(
    "contracts/My4337SmartAccount.sol:My4337SmartAccountFactory"
  );

  console.log("合约工厂加载成功");

  console.log("\n正在部署 My4337SmartAccountFactory...");

  const factory = await Factory.deploy(entryPointAddress);

  console.log("等待 Factory 部署确认...");
  await factory.waitForDeployment();

  const factoryAddress = getContractAddress(factory);

  console.log("\n✅ Factory 部署完成!");
  console.log("=".repeat(60));
  console.log("Factory 地址:", factoryAddress);

  /**
   * Factory 构造函数里会自动 new My4337SmartAccount(entryPoint_)。
   * 这个地址就是所有 clone 智能账户共用的 implementation。
   */
  const implementationAddress = await factory.implementation();
  const storedEntryPoint = await factory.entryPoint();

  console.log("Account implementation 地址:", implementationAddress);
  console.log("Factory 绑定的 EntryPoint:", storedEntryPoint);

  /**
   * 读取版本号。
   */
  const factoryVersion = await factory.version();
  console.log("Factory version:", factoryVersion);

  const implementation = await ethers.getContractAt(
    "contracts/My4337SmartAccount.sol:My4337SmartAccount",
    implementationAddress
  );

  const accountImplementationVersion = await implementation.version();
  console.log("Account implementation version:", accountImplementationVersion);

  /**
   * 预计算 owner + salt 对应的智能账户地址。
   *
   * 注意：
   * - 合约里也有 getAddress(address,bytes32)。
   * - ethers v6 合约对象自身也有 getAddress() 方法。
   * - 所以这里必须用完整函数签名调用，避免冲突。
   */
  console.log("\n预计算智能账户地址...");

  const predictedAccountAddress = await factory["getAddress(address,bytes32)"](
    ownerAddress,
    saltHex
  );

  console.log("智能账户地址:", predictedAccountAddress);

  const accountCode = await ethers.provider.getCode(predictedAccountAddress);
  const accountAlreadyDeployed = accountCode !== "0x";

  console.log(
    "智能账户是否已部署:",
    accountAlreadyDeployed ? "是" : "否"
  );

  /**
   * 生成 initCode。
   *
   * getInitCode:
   * - 无论账户是否部署，都会返回 initCode。
   *
   * getInitCodeIfNeeded:
   * - 账户未部署时返回 initCode。
   * - 账户已部署时返回 0x。
   */
  const initCodeAlways = await factory.getInitCode(ownerAddress, saltHex);
  const initCodeIfNeeded = await factory.getInitCodeIfNeeded(
    ownerAddress,
    saltHex
  );

  console.log("\ninitCode:");
  console.log("getInitCode:", initCodeAlways);
  console.log("getInitCodeIfNeeded:", initCodeIfNeeded);

  /**
   * 可选：直接创建智能账户。
   *
   * 真实 ERC-4337 流程里，通常不需要提前创建账户。
   * 第一次 UserOperation 可以带 initCode，让 EntryPoint 自动通过 Factory 创建账户。
   *
   * 但开发、测试、演示时，直接创建账户更直观。
   *
   * 使用方式：
   * CREATE_ACCOUNT=true ENTRYPOINT_ADDRESS=... npx hardhat run ...
   */
  let createdAccount = false;

  if (process.env.CREATE_ACCOUNT === "true") {
    if (accountAlreadyDeployed) {
      console.log("\n智能账户已经部署，跳过 createAccount。");
    } else {
      console.log("\nCREATE_ACCOUNT=true，正在创建智能账户...");

      const tx = await factory.createAccount(ownerAddress, saltHex);

      console.log("createAccount 交易哈希:", tx.hash);

      const receipt = await tx.wait();

      console.log("✅ createAccount 已确认，区块:", receipt.blockNumber);

      const newCode = await ethers.provider.getCode(predictedAccountAddress);

      if (newCode === "0x") {
        throw new Error("账户创建失败：预计算地址没有合约代码");
      }

      createdAccount = true;

      console.log("智能账户创建成功:", predictedAccountAddress);
    }
  }

  /**
   * 如果账户已经存在或刚刚创建，则验证账户基础功能。
   */
  const finalAccountCode = await ethers.provider.getCode(predictedAccountAddress);

  if (finalAccountCode !== "0x") {
    console.log("\n验证智能账户基础信息...");

    const account = await ethers.getContractAt(
      "contracts/My4337SmartAccount.sol:My4337SmartAccount",
      predictedAccountAddress
    );

    const accountOwner = await account.owner();
    const accountEntryPoint = await account.entryPoint();
    const accountVersion = await account.version();

    console.log("账户 owner:", accountOwner);
    console.log("账户 EntryPoint:", accountEntryPoint);
    console.log("账户 version:", accountVersion);

    console.log(
      "✓ owner 设置正确:",
      accountOwner.toLowerCase() === ownerAddress.toLowerCase()
    );

    console.log(
      "✓ EntryPoint 设置正确:",
      accountEntryPoint.toLowerCase() === entryPointAddress.toLowerCase()
    );
  } else {
    console.log("\n智能账户尚未部署，仅完成地址预计算和 initCode 生成。");
  }

  /**
   * 保存部署信息。
   */
  const deploymentsDir = path.join(__dirname, "..", "deployments");

  if (!fs.existsSync(deploymentsDir)) {
    fs.mkdirSync(deploymentsDir, { recursive: true });
  }

  const deploymentInfo = {
    network: hre.network.name,
    chainId: network.chainId.toString(),
    deployer: deployer.address,
    entryPoint: entryPointAddress,
    factory: factoryAddress,
    implementation: implementationAddress,
    factoryVersion,
    accountImplementationVersion,
    defaultOwner: ownerAddress,
    defaultSalt: saltHex,
    predictedAccount: predictedAccountAddress,
    accountAlreadyDeployed,
    createdAccount,
    initCode: initCodeAlways,
    initCodeIfNeeded,
    deployedAt: new Date().toISOString(),
  };

  const outputFile = path.join(
    deploymentsDir,
    `${hre.network.name}.My4337SmartAccountFactory.json`
  );

  fs.writeFileSync(outputFile, JSON.stringify(deploymentInfo, null, 2));

  console.log("\n部署信息已保存到:");
  console.log(outputFile);

  /**
   * 可选：验证合约。
   *
   * 使用方式：
   * VERIFY=true ENTRYPOINT_ADDRESS=... npx hardhat run ...
   *
   * 注意：
   * - Factory 是直接部署的。
   * - Implementation 是 Factory 构造函数内部 new 出来的。
   * - 两个合约的 constructor 参数都是 entryPointAddress。
   */
  if (process.env.VERIFY === "true") {
    console.log("\nVERIFY=true，准备验证合约...");
    console.log("等待区块浏览器同步...");

    await sleep(15_000);

    await tryVerify({
      address: factoryAddress,
      constructorArguments: [entryPointAddress],
      contract:
        "contracts/My4337SmartAccount.sol:My4337SmartAccountFactory",
    });

    await tryVerify({
      address: implementationAddress,
      constructorArguments: [entryPointAddress],
      contract:
        "contracts/My4337SmartAccount.sol:My4337SmartAccount",
    });
  }

  console.log("\n✅ 部署流程完成!");
  console.log("=".repeat(60));
  console.log("Factory 地址:", factoryAddress);
  console.log("Implementation 地址:", implementationAddress);
  console.log("EntryPoint 地址:", entryPointAddress);
  console.log("预计算智能账户地址:", predictedAccountAddress);
  console.log("智能账户是否已部署:", finalAccountCode !== "0x" ? "是" : "否");
  console.log("=".repeat(60));
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("\n部署失败:", error);

    if (error.transaction) {
      console.error("交易哈希:", error.transaction.hash);
    }

    process.exit(1);
  });
