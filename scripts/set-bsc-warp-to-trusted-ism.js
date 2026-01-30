const hre = require("hardhat");

async function main() {
  console.log("🔄 将 BSC Warp Route 设置为使用 TrustedRelayerIsm\n");

  // 配置
  const BSC_WARP_ROUTE = "0x946B51D0Ce14dc0e66F79dfEC086E9c618eFe41D";
  const TRUSTED_RELAYER_ISM = "0x347f8790045cD623d2DC75adA3e22aa945DB03A5";
  
  console.log("BSC Warp Route:", BSC_WARP_ROUTE);
  console.log("TrustedRelayerIsm:", TRUSTED_RELAYER_ISM);
  console.log("网络:", hre.network.name);
  console.log("");

  // 获取签名者
  const [signer] = await hre.ethers.getSigners();
  console.log("使用账户:", signer.address);
  
  const balance = await hre.ethers.provider.getBalance(signer.address);
  console.log("账户余额:", hre.ethers.formatEther(balance), "BNB\n");

  try {
    // Warp Route ABI
    const warpRouteAbi = [
      "function interchainSecurityModule() external view returns (address)",
      "function setInterchainSecurityModule(address _module) external",
      "function owner() external view returns (address)"
    ];
    
    const warpRoute = new hre.ethers.Contract(BSC_WARP_ROUTE, warpRouteAbi, signer);
    
    // 检查当前 ISM
    console.log("📍 检查当前配置...");
    const currentIsm = await warpRoute.interchainSecurityModule();
    console.log("当前 ISM:", currentIsm);
    
    // 检查 owner
    const owner = await warpRoute.owner();
    console.log("合约 Owner:", owner);
    console.log("");
    
    if (currentIsm.toLowerCase() === TRUSTED_RELAYER_ISM.toLowerCase()) {
      console.log("✅ ISM 已经是 TrustedRelayerIsm，无需更新!");
      return;
    }
    
    // 检查权限
    if (owner.toLowerCase() !== signer.address.toLowerCase()) {
      console.log("⚠️  警告: 当前账户不是合约 owner");
      console.log("   Owner:", owner);
      console.log("   当前账户:", signer.address);
      console.log("");
      console.log("❌ 无法更新 ISM，需要使用 owner 账户");
      return;
    }
    
    console.log("🔄 正在设置 ISM 为 TrustedRelayerIsm...");
    
    // 设置 ISM
    const tx = await warpRoute.setInterchainSecurityModule(TRUSTED_RELAYER_ISM);
    console.log("交易已发送:", tx.hash);
    console.log("等待确认...");
    
    const receipt = await tx.wait();
    console.log("✅ 交易已确认!");
    console.log("   Gas 使用:", receipt.gasUsed.toString());
    console.log("   区块:", receipt.blockNumber);
    console.log("");
    
    // 验证更新
    const updatedIsm = await warpRoute.interchainSecurityModule();
    console.log("更新后的 ISM:", updatedIsm);
    
    if (updatedIsm.toLowerCase() === TRUSTED_RELAYER_ISM.toLowerCase()) {
      console.log("✅ ISM 更新成功!");
      console.log("");
      console.log("🎉 完成! BSC Warp Route 现在使用 TrustedRelayerIsm");
      console.log("");
      console.log("下一步:");
      console.log("1. 运行手动中继脚本测试: ./manual-relay-single.sh");
      console.log("2. 或启动自动中继器: ./start-relayer.sh");
    } else {
      console.log("❌ 更新失败，ISM 地址不匹配!");
    }
    
  } catch (error) {
    console.log("❌ 失败:", error.message);
    if (error.data) {
      console.log("   Error data:", error.data);
    }
    console.log("");
    console.log("请检查:");
    console.log("1. 账户是否是 Warp Route 的 owner");
    console.log("2. BSC 网络连接是否正常");
    console.log("3. 账户是否有足够的 BNB 支付 gas");
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
