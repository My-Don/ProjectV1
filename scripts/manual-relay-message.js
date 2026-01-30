const hre = require("hardhat");

async function main() {
  console.log("🔄 手动中继 Hyperlane 消息\n");

  // 消息信息
  const messageId = "0xfc238963e56c1d7c8f14258eb19e45b05723664791a9e25f6616fbd8c8188c1d";
  const message = "0x03000588f70000003800000000000000000000000043dead96a7ca52d99822faf983be7c456ea779f300000c740000000000000000000000009cc3c04627a7d6bd997570aa05eb55e5b1d430e3000000000000000000000000574b09a63a6b8436cc3eeb23414b7f59d43b5883000000000000000000000000000000000000000000000000038d7ea4c68000";
  
  // Bee 链的 Mailbox 地址
  const mailboxAddress = "0x21ef2f69165348754c44AbB1327a565Aeea102ca";
  
  console.log("Message ID:", messageId);
  console.log("Mailbox:", mailboxAddress);
  console.log("");

  // 获取签名者
  const [signer] = await hre.ethers.getSigners();
  console.log("中继器地址:", signer.address);
  console.log("余额:", hre.ethers.formatEther(await hre.ethers.provider.getBalance(signer.address)), "BKC\n");

  // Mailbox ABI
  const mailboxAbi = [
    "function process(bytes calldata metadata, bytes calldata message) external payable"
  ];
  
  const mailbox = new hre.ethers.Contract(mailboxAddress, mailboxAbi, signer);
  
  console.log("🔄 正在中继消息...");
  
  try {
    // 使用空 metadata (NullMetadata)
    const metadata = "0x";
    
    const tx = await mailbox.process(metadata, message, {
      gasLimit: 500000
    });
    
    console.log("交易已发送:", tx.hash);
    console.log("等待确认...");
    
    const receipt = await tx.wait();
    console.log("✅ 交易已确认! Gas 使用:", receipt.gasUsed.toString());
    console.log("");
    console.log("🎉 消息中继成功!");
    console.log("");
    console.log("验证:");
    console.log("1. 检查 Bee 链上的余额");
    console.log("2. 访问 Hyperlane 浏览器查看消息状态");
    console.log("   https://explorer.hyperlane.xyz/message/" + messageId);
    
  } catch (error) {
    console.error("❌ 中继失败:", error.message);
    
    if (error.message.includes("already processed")) {
      console.log("\n✅ 消息已经被处理过了!");
    } else if (error.message.includes("!trustedRelayer")) {
      console.log("\n❌ 错误: 你的地址不是可信中继器");
      console.log("需要使用可信中继器地址的私钥");
    } else {
      console.log("\n可能的原因:");
      console.log("1. 需要使用可信中继器地址");
      console.log("2. 消息格式不正确");
      console.log("3. Gas 不足");
    }
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
