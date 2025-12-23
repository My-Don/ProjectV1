const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");

describe("ServerNodeBackup - Fixed", function () {
  let contract, bkcToken, rewardCalculator;
  let owner, user1, user2, signer1, signer2, signer3;

  beforeEach(async function () {
    [owner, user1, user2, signer1, signer2, signer3] = await ethers.getSigners();

    const MockERC20 = await ethers.getContractFactory("MockERC20");
    bkcToken = await MockERC20.deploy("BKC Token", "BKC");
    await bkcToken.mint(owner.address, ethers.parseEther("10000000"));

    const DecreasingRewardCalculator = await ethers.getContractFactory("DecreasingRewardCalculator");
    rewardCalculator = await DecreasingRewardCalculator.deploy();

    const ServerNodeBackupFactory = await ethers.getContractFactory("ServerNodeBackup");
    contract = await upgrades.deployProxy(
      ServerNodeBackupFactory,
      [
        owner.address,
        rewardCalculator.target,
        bkcToken.target,
        [signer1.address, signer2.address, signer3.address],
        2
      ],
      { initializer: 'initialize', kind: 'transparent' }
    );

    await contract.waitForDeployment();
    await bkcToken.transfer(await contract.getAddress(), ethers.parseEther("1000000"));
  });

  describe("Reward Distribution", function () {
    it("Should distribute rewards correctly", async function () {
  // 配置节点
  await contract.connect(owner).configNode([{
    stakeAddress: user1.address,
    isActive: true,
    typeParam: 1,
    id: 1,
    nodeCapacity: 100,
    nodeMoney: 0,
    createTime: 0,
    blockHeight: 0
  }]);

  // 记录初始状态
  const initialUserBalance = await bkcToken.balanceOf(user1.address);
  const initialContractBalance = await bkcToken.balanceOf(await contract.getAddress());
  const [initialHasRewarded, initialLastTime] = await contract.getUserRewardStatus(user1.address, 1);

  // 分配奖励
  const tx = await contract.connect(owner).configRewards([user1.address], 1);
  await tx.wait();

  // 检查最终状态
  const finalUserBalance = await bkcToken.balanceOf(user1.address);
  const finalContractBalance = await bkcToken.balanceOf(await contract.getAddress());
  const [finalHasRewarded, finalLastTime] = await contract.getUserRewardStatus(user1.address, 1);

  // 验证
  console.log("\n=== Reward Distribution Results ===");
  console.log("User balance change:", ethers.formatEther(finalUserBalance - initialUserBalance), "BKC");
  console.log("Contract balance change:", ethers.formatEther(initialContractBalance - finalContractBalance), "BKC");
  console.log("Has rewarded changed:", initialHasRewarded, "->", finalHasRewarded);
  console.log("Last time changed:", initialLastTime.toString(), "->", finalLastTime.toString());

  expect(finalUserBalance).to.be.gt(initialUserBalance);  // 用户余额增加
  expect(finalContractBalance).to.be.lt(initialContractBalance);  // 合约余额减少
  expect(finalHasRewarded).to.be.true;  // 已奖励标记为true
  expect(finalLastTime).to.be.gt(initialLastTime);  // 时间更新
});
  });
});
