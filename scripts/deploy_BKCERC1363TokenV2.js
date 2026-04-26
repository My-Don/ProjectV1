const { ethers, network, run } = require("hardhat");

async function main() {
    const [deployer] = await ethers.getSigners();

    console.log("========================================");
    console.log("开始部署 BKCERC1363Token");
    console.log("当前网络:", network.name);
    console.log("使用账户地址部署:", deployer.address);

    const balance = await ethers.provider.getBalance(deployer.address);
    console.log("部署账户余额:", ethers.formatEther(balance), "ETH");
    console.log("========================================");

    /**
     * ==============================
     * 部署参数
     * ==============================
     *
     * 注意：
     * 最终版合约里的 initialSupplyRaw / maxSupplyRaw 都是 raw units。
     * 也就是如果 ERC20 是 18 位精度：
     *
     * 600,000,000 BKC = 600000000 * 10^18
     *
     * 所以这里用 ethers.parseUnits("600000000", 18)
     */

    const TOKEN_NAME = process.env.TOKEN_NAME || "BKC Token";
    const TOKEN_SYMBOL = process.env.TOKEN_SYMBOL || "BKC";

    // 初始发行量：6 亿枚 BKC
    const INITIAL_SUPPLY = process.env.INITIAL_SUPPLY || "600000000";

    // 最大供应量：默认 10 亿枚 BKC，你可以按项目需要修改
    const MAX_SUPPLY = process.env.MAX_SUPPLY || "1000000000";

    // ERC20 默认 decimals 是 18
    const DECIMALS = 18;

    const initialSupplyRaw = ethers.parseUnits(INITIAL_SUPPLY, DECIMALS);
    const maxSupplyRaw = ethers.parseUnits(MAX_SUPPLY, DECIMALS);

    // 管理员地址，生产环境建议填多签地址
    const admin = process.env.ADMIN_ADDRESS || deployer.address;

    // Default Admin 转移延迟，单位是秒
    // 1 days = 86400
    const adminTransferDelay = Number(
        process.env.ADMIN_TRANSFER_DELAY || 24 * 60 * 60
    );

    if (!ethers.isAddress(admin)) {
        throw new Error(`ADMIN_ADDRESS 非法: ${admin}`);
    }

    if (initialSupplyRaw > maxSupplyRaw) {
        throw new Error("INITIAL_SUPPLY 不能大于 MAX_SUPPLY");
    }

    if (!Number.isSafeInteger(adminTransferDelay) || adminTransferDelay < 0) {
        throw new Error("ADMIN_TRANSFER_DELAY 必须是安全的非负整数秒数");
    }

    console.log("部署参数:");
    console.log("Token Name:", TOKEN_NAME);
    console.log("Token Symbol:", TOKEN_SYMBOL);
    console.log("Initial Supply:", INITIAL_SUPPLY, TOKEN_SYMBOL);
    console.log("Max Supply:", MAX_SUPPLY, TOKEN_SYMBOL);
    console.log("Admin:", admin);
    console.log("Admin Transfer Delay:", adminTransferDelay, "seconds");
    console.log("========================================");

    const BKCERC1363Token = await ethers.getContractFactory("BKCERC1363Token");

    const token = await BKCERC1363Token.deploy(
        TOKEN_NAME,
        TOKEN_SYMBOL,
        initialSupplyRaw,
        maxSupplyRaw,
        admin,
        adminTransferDelay
    );

    await token.waitForDeployment();

    const tokenAddress = await token.getAddress();

    console.log("✅ BKCERC1363Token 部署成功");
    console.log("合约地址:", tokenAddress);

    const deploymentTx = token.deploymentTransaction();

    if (deploymentTx) {
        console.log("部署交易 Hash:", deploymentTx.hash);
    }

    console.log("========================================");

    /**
     * 读取部署后的基本信息，确认部署结果
     */
    const name = await token.name();
    const symbol = await token.symbol();
    const decimals = await token.decimals();
    const totalSupply = await token.totalSupply();
    const cap = await token.cap();
    const frozenCount = await token.frozenCount();

    console.log("链上确认信息:");
    console.log("Name:", name);
    console.log("Symbol:", symbol);
    console.log("Decimals:", decimals.toString());
    console.log("Total Supply:", ethers.formatUnits(totalSupply, decimals), symbol);
    console.log("Cap:", ethers.formatUnits(cap, decimals), symbol);
    console.log("Frozen Count:", frozenCount.toString());

    console.log("========================================");

    /**
     * 读取角色，确认 admin 是否拥有初始权限
     */
    const DEFAULT_ADMIN_ROLE = await token.DEFAULT_ADMIN_ROLE();
    const MINTER_ROLE = await token.MINTER_ROLE();
    const FREEZER_ROLE = await token.FREEZER_ROLE();

    const hasDefaultAdminRole = await token.hasRole(DEFAULT_ADMIN_ROLE, admin);
    const hasMinterRole = await token.hasRole(MINTER_ROLE, admin);
    const hasFreezerRole = await token.hasRole(FREEZER_ROLE, admin);

    console.log("角色确认:");
    console.log("Admin has DEFAULT_ADMIN_ROLE:", hasDefaultAdminRole);
    console.log("Admin has MINTER_ROLE:", hasMinterRole);
    console.log("Admin has FREEZER_ROLE:", hasFreezerRole);

    console.log("========================================");

    /**
     * 可选：自动验证合约
     *
     * 需要你安装并配置 hardhat verify 插件，例如：
     * npm install --save-dev @nomicfoundation/hardhat-verify
     *
     * 并在 hardhat.config.js 里配置 etherscan api key。
     */
    const shouldVerify =
        process.env.VERIFY === "true" &&
        network.name !== "hardhat" &&
        network.name !== "localhost";

    if (shouldVerify) {
        console.log("等待几个区块后开始验证合约...");

        if (deploymentTx) {
            await deploymentTx.wait(5);
        }

        try {
            await run("verify:verify", {
                address: tokenAddress,
                constructorArguments: [
                    TOKEN_NAME,
                    TOKEN_SYMBOL,
                    initialSupplyRaw,
                    maxSupplyRaw,
                    admin,
                    adminTransferDelay,
                ],
            });

            console.log("✅ 合约验证成功");
        } catch (error) {
            console.error("⚠️ 合约验证失败:");
            console.error(error.message || error);
        }
    }

    console.log("========================================");
    console.log("部署完成");
    console.log("BKCERC1363Token:", tokenAddress);
    console.log("========================================");
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error("❌ 部署失败:");
        console.error(error);
        process.exit(1);
    });