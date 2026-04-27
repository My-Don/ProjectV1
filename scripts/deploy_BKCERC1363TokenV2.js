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
     * =====================================================
     * 合约部署参数
     * =====================================================
     *
     * 注意：
     * 最终版合约里的 initialSupplyRaw / maxSupplyRaw
     * 都是 raw units，也就是最小单位。
     *
     * ERC20 默认 decimals = 18。
     *
     * 所以：
     * 1 个 BKC = 1 * 10^18
     * 600,000,000 个 BKC = 600000000 * 10^18
     */

    // 代币名称
    const TOKEN_NAME = process.env.TOKEN_NAME || "BKC Token";

    // 代币简称
    const TOKEN_SYMBOL = process.env.TOKEN_SYMBOL || "BKC";

    // 初始发行量：6 亿枚 BKC
    const INITIAL_SUPPLY = process.env.INITIAL_SUPPLY || "600000000";

    // 最大供应量：10 亿枚 BKC
    // 如果你不想后续继续增发，可以改成和 INITIAL_SUPPLY 一样：600000000
    const MAX_SUPPLY = process.env.MAX_SUPPLY || "1000000000";

    // ERC20 默认精度是 18
    const DECIMALS = 18;

    // 把普通数量转换成 raw units
    const initialSupplyRaw = ethers.parseUnits(INITIAL_SUPPLY, DECIMALS);
    const maxSupplyRaw = ethers.parseUnits(MAX_SUPPLY, DECIMALS);

    // 初始管理员地址
    // 这个地址会拿到 DEFAULT_ADMIN_ROLE、MINTER_ROLE、FREEZER_ROLE
    // 生产环境建议换成多签钱包地址
    const admin = process.env.ADMIN_ADDRESS || deployer.address;

    // 默认管理员权限转移延迟，单位：秒
    // 86400 秒 = 1 天
    const adminTransferDelay = Number(
        process.env.ADMIN_TRANSFER_DELAY || 24 * 60 * 60
    );

    /**
     * =====================================================
     * 参数检查
     * =====================================================
     */

    if (!ethers.isAddress(admin)) {
        throw new Error(`管理员地址不合法: ${admin}`);
    }

    if (initialSupplyRaw > maxSupplyRaw) {
        throw new Error("初始发行量不能大于最大供应量");
    }

    if (!Number.isSafeInteger(adminTransferDelay) || adminTransferDelay < 0) {
        throw new Error("管理员转移延迟必须是安全的非负整数");
    }

    console.log("部署参数:");
    console.log("代币名称:", TOKEN_NAME);
    console.log("代币简称:", TOKEN_SYMBOL);
    console.log("初始发行量:", INITIAL_SUPPLY, TOKEN_SYMBOL);
    console.log("最大供应量:", MAX_SUPPLY, TOKEN_SYMBOL);
    console.log("管理员地址:", admin);
    console.log("管理员转移延迟:", adminTransferDelay, "秒");
    console.log("========================================");

    /**
     * =====================================================
     * 部署合约
     * =====================================================
     */

    const BKCERC1363Token = await ethers.getContractFactory("BKCERC1363TokenV2");

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
     * =====================================================
     * 部署后读取链上数据，确认部署没问题
     * =====================================================
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
    console.log(
        "Total Supply:",
        ethers.formatUnits(totalSupply, decimals),
        symbol
    );
    console.log(
        "Max Supply Cap:",
        ethers.formatUnits(cap, decimals),
        symbol
    );
    console.log("Frozen Count:", frozenCount.toString());

    console.log("========================================");

    /**
     * =====================================================
     * 检查管理员角色
     * =====================================================
     */

    const DEFAULT_ADMIN_ROLE = await token.DEFAULT_ADMIN_ROLE();
    const MINTER_ROLE = await token.MINTER_ROLE();
    const FREEZER_ROLE = await token.FREEZER_ROLE();

    const hasDefaultAdminRole = await token.hasRole(DEFAULT_ADMIN_ROLE, admin);
    const hasMinterRole = await token.hasRole(MINTER_ROLE, admin);
    const hasFreezerRole = await token.hasRole(FREEZER_ROLE, admin);

    console.log("角色检查:");
    console.log("管理员拥有 DEFAULT_ADMIN_ROLE:", hasDefaultAdminRole);
    console.log("管理员拥有 MINTER_ROLE:", hasMinterRole);
    console.log("管理员拥有 FREEZER_ROLE:", hasFreezerRole);

    console.log("========================================");

    /**
     * =====================================================
     * 可选：自动验证合约
     * =====================================================
     *
     * 使用方法：
     * VERIFY=true npx hardhat run scripts/deploy.js --network sepolia
     *
     * 前提：
     * 你已经安装并配置了 hardhat verify 插件。
     */

    const shouldVerify =
        process.env.VERIFY === "true" &&
        network.name !== "hardhat" &&
        network.name !== "localhost";

    if (shouldVerify) {
        console.log("准备验证合约...");

        if (deploymentTx) {
            console.log("等待 5 个区块后开始验证...");
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
