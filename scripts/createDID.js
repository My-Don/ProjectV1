// // install: npm install did-resolver ethr-did-resolver ethers
require("dotenv").config()
const { Resolver } = require('did-resolver')
const { getResolver } = require('ethr-did-resolver')
const { ethers } = require('ethers')
const { createEnsPublicClient } = require('@ensdomains/ensjs')
const { http } = require('viem')
const { mainnet, sepolia } = require('viem/chains')




if (!process.env.MONAD_TESTNET_RPC_URL || !process.env.MONAD_MAINNET_RPC_URL || !process.env.MAINNET_URL || !process.env.BSCMAINNET_URL) {
    console.error("Please set your MONAD_RPC_URL in a .env file")
    process.exit(1)
}


// 初始化 ENS 客户端
const client = createEnsPublicClient({
    // chain: mainnet,
    chain: sepolia,
    transport: http(),
})
console.log("ens：", client);

console.log("ENS 客户端初始化完成");

// // 检查你的provider配置
// const provider = new ethers.JsonRpcProvider("https://eth.llamarpc.com")

// const ethrDidResolver = getResolver({
//   networks: [
//     { name: 'mainnet', rpcUrl: process.env.MAINNET_URL, chainId: 1, skipRegistryLookup: true  },
//     { name: 'bsc', rpcUrl: process.env.BSCMAINNET_URL, chainId: 56, skipRegistryLookup: true  },
//     { name: 'monad-testnet', rpcUrl: process.env.MONAD_TESTNET_RPC_URL, chainId: 10143, skipRegistryLookup: true },
//     { name: 'monad-mainnet', rpcUrl: process.env.MONAD_MAINNET_RPC_URL, chainId: 143, skipRegistryLookup: true },
//   ]
// })

// const resolver = new Resolver(ethrDidResolver)

// async function generateDidDocument(ethAddress, networkName = 'mainnet') {
//   const did = `did:ethr:${networkName}:${ethAddress}`
//   return await resolver.resolve(did)
// }

// async function main() {

//     const block = await provider.getBlockNumber()

//     console.log("Current block number: " + block)

//     // 示例调用
//     const doc = await generateDidDocument('0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045')
//     console.log(JSON.stringify(doc, null, 2))

// }

// main().catch((error) => {
//   console.error(error);
//   process.exitCode = 1;
// })

function getSecret() {
    const name = "88888888";
    const hashedName = ethers.keccak256(ethers.toUtf8Bytes(name));
    const secretArray = ethers.toUtf8Bytes(hashedName);
    //const secretArray = ethers.randomBytes(32);
    const secretHex = ethers.hexlify(secretArray);
    console.log("Secret (Uint8Array):", secretArray);
    console.log("Secret (Hex string):", secretHex);
    return secretHex;
}


// 先创建did
async function setDIDAttribute() {
    // 1. 连接到rpc网络
    const provider = new ethers.JsonRpcProvider(process.env.SEPOLIA_URL);
    const wallet = new ethers.Wallet(process.env.PRIVATE_KEY, provider);

    // 2. DID EthereumDIDRegistry合约地址
    const contractAddress = '0x2654ddb11e416f000F10C0f289a904745D812B8a';
    const abi = require("../artifacts/contracts/EthereumDIDRegistry.sol/EthereumDIDRegistry.json").abi;
    // 3. 创建合约实例
    const didRegistry = new ethers.Contract(contractAddress, abi, wallet);

    // 4. 生成DID
    const did = `did:ethr:${wallet.address.toLowerCase()}`;

    // 5. 准备参数
    const name = "xhh";
    const hashedName = ethers.keccak256(ethers.toUtf8Bytes(name));
    const value = ethers.toUtf8Bytes("alice:eth");
    const validity = 86400; // 1天

    // 6. 调用setAttribute
    const tx = await didRegistry.setAttribute(
        wallet.address,
        hashedName,
        value,
        validity
    );

    console.log('Transaction hash:', tx.hash);
    console.log('DID:', did);
    console.log('Attribute set successfully');
}

// 绑定ens

async function main() {
    //await setDIDAttribute();
    getSecret();
}

main().catch((error) => {
    console.error(error);
})