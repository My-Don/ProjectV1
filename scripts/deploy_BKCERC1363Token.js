const { ethers, upgrades } = require("hardhat");


async function main() {
    const [deployer] = await ethers.getSigners();
    console.log("使用账户地址部署:", deployer.address);


    // 先部署一个erc20合约
    const ERC20 = await ethers.getContractFactory("BKCERC1363Token");
    const erc20 = await ERC20.deploy("BKC Token", "BKC", 600000000, deployer.address);
    await erc20.waitForDeployment();

    const erc20Address = await erc20.getAddress();
    console.log("✅ BKC 部署成功:", erc20Address);

}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);

    });
