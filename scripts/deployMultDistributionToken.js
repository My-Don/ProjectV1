const { ethers, upgrades } = require("hardhat");


async function main() {
    const [deployer] = await ethers.getSigners();
    console.log("使用账户地址部署:", deployer.address);

    // seolia testnet BKC address
    const bkc = "0x10Cd98b7DDaB859754AB67dD26fb3110609cCD03";

    const MultDistributionToken = await ethers.getContractFactory("MultDistributionToken");
    const multDistributionToken = await MultDistributionToken.deploy(bkc);
    await multDistributionToken.waitForDeployment();

    const multDistributionTokenAddress = await multDistributionToken.getAddress();
    console.log("✅ MultDistributionToken 部署成功:", multDistributionTokenAddress);


}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });