const { ethers } = require("hardhat");

//viem 是一个现代化的轻量、类型安全且易于使用, 以太坊 JavaScript/TypeScript 工具库，专为与以太坊区块链交互而设计。
// 它提供了一系列实用函数，简化了与智能合约的交互、数据编码/解码、哈希计算等操作
// ENS 相关操作
// labelhash 计算 ENS 域名标签的哈希值, namehash 计算完整 ENS 域名的哈希值
// encodeFunctionData 编码智能合约函数调用数据, hexToBigInt 将十六进制字符串转换为 BigInt 类型
// zeroAddress 零地址（0x0000000000000000000000000000000000000000）
// zeroHash 零哈希（0x0000000000000000000000000000000000000000000000000000000000000000）
// npm install viem
const {
  encodeFunctionData,
  hexToBigInt,
  labelhash,
  namehash,
  zeroAddress,
  zeroHash,
} = require('viem');


 // 部署 ENS + DID 整个流程所涉及的合约
async function main() {
    const [deployer] = await ethers.getSigners();
    console.log("使用账户地址部署:", deployer.address);

    console.log("开始部署 ENS + DID 整个流程所涉及的合约......");

    // 部署EthereumDIDRegistry合约
    const EthereumDIDRegistry = await ethers.getContractFactory("EthereumDIDRegistry");
    const didRegistry = await EthereumDIDRegistry.deploy();
    await didRegistry.waitForDeployment();

    const didRegistryAddress = await didRegistry.getAddress();
    console.log("✅ EthereumDIDRegistry 部署成功:", didRegistryAddress);

    // 部署ENSRegistry合约
    const ENSRegistry = await ethers.getContractFactory("ENSRegistry");
    const eNSRegistry = await ENSRegistry.deploy();
    await eNSRegistry.waitForDeployment();

    const eNSRegistryAddress = await eNSRegistry.getAddress();
    console.log("✅ ENSRegistry 部署成功:", eNSRegistryAddress);

    // 部署 ReverseRegistrar
    const ReverseRegistrar = await ethers.getContractFactory("ReverseRegistrar");
    const reverseRegistrar = await ReverseRegistrar.deploy(deployer.address, eNSRegistryAddress);
    await reverseRegistrar.waitForDeployment();

    const reverseRegistrarAddress = await reverseRegistrar.getAddress();
    console.log("✅ ReverseRegistrar 部署成功:", reverseRegistrarAddress);

    // 部署 DefaultReverseRegistrar
    const DefaultReverseRegistrar = await ethers.getContractFactory("DefaultReverseRegistrar");
    const defaultReverseRegistrar = await DefaultReverseRegistrar.deploy(deployer.address);
    await defaultReverseRegistrar.waitForDeployment();

    const defaultReverseRegistrarAddress = await defaultReverseRegistrar.getAddress();
    console.log("✅ DefaultReverseRegistrar 部署成功:", defaultReverseRegistrarAddress);

    // 设置反向注册器节点所有权
    console.log('Setting up reverse registrar nodes...');
    await eNSRegistry.setSubnodeOwner(zeroHash, labelhash('reverse'), deployer.address);
    await eNSRegistry.setSubnodeOwner(namehash('reverse'), labelhash('addr'), reverseRegistrarAddress);

    // 部署 BaseRegistrarImplementation
    const BaseRegistrarImplementation = await ethers.getContractFactory("BaseRegistrarImplementation");
    const baseRegistrarImplementation = await BaseRegistrarImplementation.deploy(eNSRegistryAddress, namehash('eth'), deployer.address);
    await baseRegistrarImplementation.waitForDeployment();

    const baseRegistrarImplementationAddress = await baseRegistrarImplementation.getAddress();
    console.log("✅ BaseRegistrarImplementation 部署成功:", baseRegistrarImplementationAddress);

    // 部署 MockMetadataService
    const MockMetadataService = await ethers.getContractFactory("MockMetadataService");
    const mockMetadataService = await MockMetadataService.deploy();
    await mockMetadataService.waitForDeployment();

    const mockMetadataServiceAddress = await mockMetadataService.getAddress();
    console.log("✅ MockMetadataService 部署成功:", mockMetadataServiceAddress);

    // 部署 NameWrapper
    const NameWrapper = await ethers.getContractFactory("NameWrapper");
    const nameWrapper = await NameWrapper.deploy(deployer.address, eNSRegistryAddress, baseRegistrarImplementationAddress, mockMetadataServiceAddress);
    await nameWrapper.waitForDeployment();

    const nameWrapperAddress = await nameWrapper.getAddress();
    console.log("✅ NameWrapper 部署成功:", nameWrapperAddress);

    // 部署 DummyOracle
    const DummyOracle = await ethers.getContractFactory("DummyOracle");
    const dummyOracle = await DummyOracle.deploy(100000000n);
    await dummyOracle.waitForDeployment();

    const dummyOracleAddress = await dummyOracle.getAddress();
    console.log("✅ DummyOracle 部署成功:", dummyOracleAddress);

    // 部署 StablePriceOracle
    const StablePriceOracle = await ethers.getContractFactory("StablePriceOracle");
    const stablePriceOracle = await StablePriceOracle.deploy(dummyOracleAddress, [0n, 0n, 4n, 2n, 1n]);
    await stablePriceOracle.waitForDeployment();

    const stablePriceOracleAddress = await stablePriceOracle.getAddress();
    console.log("✅ StablePriceOracle 部署成功:", stablePriceOracleAddress);

    // 部署 ETHRegistrarController
    const ETHRegistrarController = await ethers.getContractFactory("ETHRegistrarController");
    const registrarController = await ETHRegistrarController.deploy(
        deployer.address,
        baseRegistrarImplementationAddress,
        stablePriceOracleAddress,
        600n,
        86400n,
        reverseRegistrarAddress,
        defaultReverseRegistrarAddress,
        eNSRegistryAddress
    );
    await registrarController.waitForDeployment();

    const registrarControllerAddress = await registrarController.getAddress();
    console.log("✅ ETHRegistrarController 部署成功:", registrarControllerAddress);

    // 部署 PublicResolver
    const PublicResolver = await ethers.getContractFactory("PublicResolver");
    const publicResolver = await PublicResolver.deploy(eNSRegistryAddress, nameWrapperAddress, registrarControllerAddress, reverseRegistrarAddress);
    await publicResolver.waitForDeployment();

    const publicResolverAddress = await publicResolver.getAddress();
    console.log("✅ PublicResolver 部署成功:", publicResolverAddress);

    console.log("结束部署 ENS + DID 整个流程所涉及的合约......");

}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });