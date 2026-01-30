require("dotenv").config()
const { ethers } = require('ethers')


const ERC20_ABI = [
    "function approve(address spender, uint256 amount) public returns (bool)",
    "function allowance(address owner, address spender) public view returns (uint256)",
    "function balanceOf(address account) public view returns (uint256)",
    "function decimals() public view returns (uint8)",
    "function symbol() public view returns (string)",
    "function name() public view returns (string)",
    "function transferOwnership(address newOwner) public",
    "function owner() public view returns (address)" 
]

const arb_provider = new ethers.JsonRpcProvider("https://sepolia-rollup.arbitrum.io/rpc")

const base_provider = new ethers.JsonRpcProvider("https://sepolia.base.org")

const ARB_USDT = "0x87ef6FAe84C6322b907D3F07754276dDED94C501"
const BASE_USDT = "0x35430d5DE783051f6aa2c2AD27F4D1e13aaABa2D"
const ARB_MyUSDTMintBurnOFTAdapter = "0x044Ed509FfD11ff8B5eA85a1D2d8ea5C0652CCc6"
const BASE_MyUSDTMintBurnOFTAdapter = "0xF70e01f57A76674728b9986f688A3327c943A88e"


const wallet = new ethers.Wallet(process.env.PRIVATE_KEY, arb_provider)
console.log("arb sepolia 钱包地址:", wallet.address)


const walletV2 = new ethers.Wallet(process.env.PRIVATE_KEY, base_provider)
console.log("base sepolia 钱包地址:", walletV2.address)


async function main() {

    // 3. 创建arb_sepolia合约对象
    const arb_tokenContract = new ethers.Contract(
        ARB_USDT,
        ERC20_ABI,
        wallet // 使用签名者，这样可以直接调用合约方法
    )

    // 3. 创建base_sepolia合约对象
    const base_tokenContract = new ethers.Contract(
        BASE_USDT,
        ERC20_ABI,
        walletV2 // 使用签名者，这样可以直接调用合约方法
    )

    // 4.发送交易
    const tx = await arb_tokenContract.transferOwnership(ARB_MyUSDTMintBurnOFTAdapter)
    console.log("arb sepolia交易哈希:", tx.hash)
    console.log("等待交易确认...")

    // 等待交易确认
    const receipt = await tx.wait()
    console.log("\n=== arb sepolia 交易确认 ===")
    console.log("交易状态:", receipt.status === 1 ? "成功" : "失败")
    console.log("区块号:", receipt.blockNumber)
    console.log("Gas 使用:", receipt.gasUsed.toString())


    // 4.发送交易
     const owner = await base_tokenContract.owner();
     console.log("owner: ", owner);

    const txV2 = await base_tokenContract.transferOwnership(BASE_MyUSDTMintBurnOFTAdapter)
    console.log("base sepolia 交易哈希:", txV2.hash)
    console.log("等待交易确认...")

    // 等待交易确认
    const receiptV2 = await txV2.wait()
    console.log("\n=== base sepolia 交易确认 ===")
    console.log("交易状态:", receiptV2.status === 1 ? "成功" : "失败")
    console.log("区块号:", receiptV2.blockNumber)
    console.log("Gas 使用:", receiptV2.gasUsed.toString())


}





main()