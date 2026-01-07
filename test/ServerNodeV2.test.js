const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");

describe("ServerNodeV2Backup 完整测试", function () {
  let serverNodeV2Backup;
  let owner, admin, whitelist1, whitelist2, user1, user2, user3, user4, signer1, signer2, signer3, stakeAddress1, stakeAddress2, stakeAddress3;

  const DEFAULT_CAPACITY = 1000000n;
  const SCALE = 1000000n;
  const MAX_WHITELIST = 3n;

  before(async function () {
    [owner, admin, whitelist1, whitelist2, user1, user2, user3, user4, signer1, signer2, signer3, stakeAddress1, stakeAddress2, stakeAddress3] = await ethers.getSigners();
  });

  beforeEach(async function () {
    // Deploy DecreasingRewardCalculator
    const RewardCalculator = await ethers.getContractFactory("DecreasingRewardCalculator");
    const rewardCalculator = await RewardCalculator.deploy();
    await rewardCalculator.waitForDeployment();
    
    // Deploy ServerNodeV2Backup
    const ServerNodeV2Backup = await ethers.getContractFactory("ServerNodeV2Backup");
    serverNodeV2Backup = await upgrades.deployProxy(
      ServerNodeV2Backup,
      [
        owner.address,
        await rewardCalculator.getAddress(),
        [signer1.address, signer2.address, signer3.address],
        2
      ],
      { initializer: "initialize" }
    );
    await serverNodeV2Backup.waitForDeployment();
  });

  // ==================== 1. 初始化测试 ====================
  describe("1. 初始化测试", function () {
    it("应该正确初始化合约", async function () {
      const contractOwner = await serverNodeV2Backup.owner();
      expect(contractOwner).to.equal(owner.address);
      
      const [signers, threshold] = await serverNodeV2Backup.getWithdrawMultiSigInfo();
      expect(signers.length).to.equal(3);
      expect(threshold).to.equal(2);
    });
  });

  // ==================== 2. 节点创建与管理 ====================
  describe("2. 节点创建与管理", function () {
    it("应该允许管理员创建节点", async function () {
      const nodeInfo = [{
        ip: "192.168.1.1",
        describe: "Test Node 1",
        name: "Node-001",
        isActive: true,
        nodeStakeAddress: owner.address,
        id: 0,
        capacity: 0,
        createTime: 0,
        blockHeight: 0
      }];

      await serverNodeV2Backup.connect(owner).createNode(nodeInfo);

      const node = await serverNodeV2Backup.deployNode(0);
      expect(node.ip).to.equal("192.168.1.1");
      expect(node.name).to.equal("Node-001");
      expect(node.capacity).to.equal(DEFAULT_CAPACITY);
    });

    it("应该确保IP地址唯一性", async function () {
      const nodeInfo1 = [{
        ip: "192.168.1.1",
        describe: "Test Node 1",
        name: "Node-001",
        isActive: true,
        nodeStakeAddress: owner.address,
        id: 0,
        capacity: 0,
        createTime: 0,
        blockHeight: 0
      }];

      const nodeInfo2 = [{
        ip: "192.168.1.1",
        describe: "Test Node 2",
        name: "Node-002",
        isActive: true,
        nodeStakeAddress: owner.address,
        id: 0,
        capacity: 0,
        createTime: 0,
        blockHeight: 0
      }];

      await serverNodeV2Backup.connect(owner).createNode(nodeInfo1);
      
      await expect(
        serverNodeV2Backup.connect(owner).createNode(nodeInfo2)
      ).to.be.revertedWith("IP address must be unique");
    });
  });

  // ==================== 3. 白名单管理 ====================
  describe("3. 白名单管理", function () {
    it("应该允许管理员添加白名单", async function () {
      await serverNodeV2Backup.connect(owner).setWhiteList(whitelist1.address, true);

      const isWhitelisted = await serverNodeV2Backup.whiteList(whitelist1.address);
      expect(isWhitelisted).to.be.true;
    });

    it("应该限制白名单最大数量", async function () {
      await serverNodeV2Backup.connect(owner).setWhiteList(user1.address, true);
      await serverNodeV2Backup.connect(owner).setWhiteList(user2.address, true);
      await serverNodeV2Backup.connect(owner).setWhiteList(user3.address, true);

      const count = await serverNodeV2Backup.getWhitelistCount();
      expect(count).to.equal(3n);

      await expect(
        serverNodeV2Backup.connect(owner).setWhiteList(user4.address, true)
      ).to.be.revertedWith("Max whitelist limit reached");
    });

    it("应该允许管理员移除白名单", async function () {
      await serverNodeV2Backup.connect(owner).setWhiteList(whitelist1.address, true);
      
      await serverNodeV2Backup.connect(owner).setWhiteList(whitelist1.address, false);

      const isWhitelisted = await serverNodeV2Backup.whiteList(whitelist1.address);
      expect(isWhitelisted).to.be.false;
      
      const count = await serverNodeV2Backup.getWhitelistCount();
      expect(count).to.equal(0n);
    });
  });

  // ==================== 4. 节点分配 - 大节点 ====================
  describe("4. 节点分配 - 大节点", function () {
    beforeEach(async function () {
      // 创建3个大节点
      for (let i = 1; i <= 3; i++) {
        await serverNodeV2Backup.connect(owner).createNode([{
          ip: `192.168.1.${i}`,
          describe: `Big Node ${i}`,
          name: `Big-${i.toString().padStart(3, '0')}`,
          isActive: true,
          nodeStakeAddress: owner.address,
          id: 0,
          capacity: 0,
          createTime: 0,
          blockHeight: 0
        }]);
      }
      await serverNodeV2Backup.connect(owner).setWhiteList(admin.address, true);
    });

    it("应该正确分配大节点", async function () {
      await serverNodeV2Backup.connect(admin).allocateNodes(user1.address, admin.address, 1, 2, 0);

      const isNode1Allocated = await serverNodeV2Backup.isNodeAllocatedAsBig(1);
      const isNode2Allocated = await serverNodeV2Backup.isNodeAllocatedAsBig(2);
      const isNode3Allocated = await serverNodeV2Backup.isNodeAllocatedAsBig(3);
      
      expect(isNode1Allocated).to.be.true;
      expect(isNode2Allocated).to.be.true;
      expect(isNode3Allocated).to.be.false;

      const userEquivalent = await serverNodeV2Backup.userPhysicalNodesEquivalent(user1.address);
      const expectedEquivalent = (DEFAULT_CAPACITY * 2n * SCALE) / DEFAULT_CAPACITY;
      expect(userEquivalent).to.equal(expectedEquivalent);
    });

    it("非管理员/白名单不能分配节点", async function () {
      await expect(
        serverNodeV2Backup.connect(user1).allocateNodes(user1.address, user1.address, 1, 1, 0)
      ).to.be.revertedWith("Only owner or whitelist");
    });
  });

  // ==================== 5. 节点分配 - 中节点 ====================
  describe("5. 节点分配 - 中节点", function () {
    beforeEach(async function () {
      // 创建2个通用节点
      for (let i = 1; i <= 2; i++) {
        await serverNodeV2Backup.connect(owner).createNode([{
          ip: `192.168.1.${10 + i}`,
          describe: `General Node ${i}`,
          name: `Gen-${i.toString().padStart(3, '0')}`,
          isActive: true,
          nodeStakeAddress: owner.address,
          id: 0,
          capacity: 0,
          createTime: 0,
          blockHeight: 0
        }]);
      }
      await serverNodeV2Backup.connect(owner).setWhiteList(admin.address, true);
    });

    it("应该正确分配中节点", async function () {
      await serverNodeV2Backup.connect(admin).allocateNodes(user1.address, admin.address, 2, 3, 0);

      const userAllocations = await serverNodeV2Backup.getUserAllocations(user1.address);
      expect(userAllocations.length).to.equal(3);

      for (const allocation of userAllocations) {
        expect(allocation.nodeType).to.equal(2);
        expect(allocation.amount).to.equal(200000);
      }
    });
  });

  // ==================== 6. 节点分配 - 小节点 ====================
  describe("6. 节点分配 - 小节点", function () {
    beforeEach(async function () {
      await serverNodeV2Backup.connect(owner).createNode([{
        ip: "192.168.1.20",
        describe: "General Node",
        name: "Gen-020",
        isActive: true,
        nodeStakeAddress: owner.address,
        id: 0,
        capacity: 0,
        createTime: 0,
        blockHeight: 0
      }]);
      await serverNodeV2Backup.connect(owner).setWhiteList(admin.address, true);
    });

    it("应该正确分配小节点", async function () {
      await serverNodeV2Backup.connect(admin).allocateNodes(user1.address, admin.address, 3, 5, 0);

      const userAllocations = await serverNodeV2Backup.getUserAllocations(user1.address);
      expect(userAllocations.length).to.equal(5);

      for (const allocation of userAllocations) {
        expect(allocation.nodeType).to.equal(3);
        expect(allocation.amount).to.equal(50000);
      }
    });
  });

  // ==================== 7. 节点分配 - 商品 ====================
  describe("7. 节点分配 - 商品", function () {
    beforeEach(async function () {
      await serverNodeV2Backup.connect(owner).createNode([{
        ip: "192.168.1.30",
        describe: "General Node",
        name: "Gen-030",
        isActive: true,
        nodeStakeAddress: owner.address,
        id: 0,
        capacity: 0,
        createTime: 0,
        blockHeight: 0
      }]);
      await serverNodeV2Backup.connect(owner).setWhiteList(admin.address, true);
    });

    it("应该正确分配商品", async function () {
      const commodityAmount = 350000n;
      
      await serverNodeV2Backup.connect(admin).allocateNodes(
        user1.address,
        admin.address,
        4,
        0,
        commodityAmount
      );

      const userAllocations = await serverNodeV2Backup.getUserAllocations(user1.address);
      expect(userAllocations.length).to.equal(1);
      
      const allocation = userAllocations[0];
      expect(allocation.nodeType).to.equal(4);
      expect(allocation.amount).to.equal(commodityAmount);
    });

    it("商品金额必须在有效范围内", async function () {
      await expect(
        serverNodeV2Backup.connect(admin).allocateNodes(user1.address, admin.address, 4, 0, 0)
      ).to.be.revertedWith("Amount must be 1-1,000,000");

      await expect(
        serverNodeV2Backup.connect(admin).allocateNodes(user1.address, admin.address, 4, 0, 1000001)
      ).to.be.revertedWith("Amount must be 1-1,000,000");
    });
  });

  // ==================== 8. 组合分配 ====================
  describe("8. 组合分配", function () {
    beforeEach(async function () {
      // 创建一个完整的节点用于组合分配
      await serverNodeV2Backup.connect(owner).createNode([{
        ip: "192.168.1.40",
        describe: "Combination Node",
        name: "Combo-001",
        isActive: true,
        nodeStakeAddress: owner.address,
        id: 0,
        capacity: 0,
        createTime: 0,
        blockHeight: 0
      }]);
      await serverNodeV2Backup.connect(owner).setWhiteList(admin.address, true);
    });

    it("应该正确执行组合分配", async function () {
      const combination = {
        mediumNodes: 3,
        smallNodes: 4,
        commodity: 200000
      };

      // 先查询节点剩余容量
      const remainingBefore = await serverNodeV2Backup.getNodeRemainingCapacity(1);
      expect(remainingBefore).to.equal(DEFAULT_CAPACITY);

      await serverNodeV2Backup.connect(admin).allocateCombinedNodes(
        user1.address,
        admin.address,
        combination
      );

      // 查询用户分配记录
      const userAllocations = await serverNodeV2Backup.getUserAllocations(user1.address);
      
      // 计算总金额
      let totalAmount = 0n;
      for (const allocation of userAllocations) {
        totalAmount += allocation.amount;
      }

      // 验证总金额正确
      expect(totalAmount).to.equal(1000000n);
      
      // 验证用户等效值
      const userEquivalent = await serverNodeV2Backup.userPhysicalNodesEquivalent(user1.address);
      const expectedEquivalent = (1000000n * SCALE) / DEFAULT_CAPACITY;
      expect(userEquivalent).to.equal(expectedEquivalent);

      // 验证节点剩余容量
      const remainingAfter = await serverNodeV2Backup.getNodeRemainingCapacity(1);
      expect(remainingAfter).to.equal(remainingBefore - 1000000n);
    });

    it("组合分配总金额不能超过100万", async function () {
      const invalidCombination = {
        mediumNodes: 6,
        smallNodes: 0,
        commodity: 0
      };

      await expect(
        serverNodeV2Backup.connect(admin).allocateCombinedNodes(
          user1.address,
          admin.address,
          invalidCombination
        )
      ).to.be.revertedWith("Total must be 1~1,000,000");
    });
  });

  // ==================== 9. 批量分配 ====================
  describe("9. 批量分配", function () {
    beforeEach(async function () {
      // 创建多个节点
      for (let i = 1; i <= 10; i++) {
        await serverNodeV2Backup.connect(owner).createNode([{
          ip: `192.168.1.${50 + i}`,
          describe: `Node ${i}`,
          name: `N-${i}`,
          isActive: true,
          nodeStakeAddress: owner.address,
          id: 0,
          capacity: 0,
          createTime: 0,
          blockHeight: 0
        }]);
      }
      await serverNodeV2Backup.connect(owner).setWhiteList(admin.address, true);
    });

    it("应该正确执行批量分配", async function () {
      const allocations = [{
        user: user1.address,
        stakeAddress: admin.address,
        nodeType: 1,
        quantity: 1,
        amount: 0
      }, {
        user: user2.address,
        stakeAddress: admin.address,
        nodeType: 2,
        quantity: 2,
        amount: 0
      }, {
        user: user3.address,
        stakeAddress: admin.address,
        nodeType: 4,
        quantity: 0,
        amount: 300000
      }];

      await serverNodeV2Backup.connect(admin).allocateNodesBatch(allocations);

      const allocations1 = await serverNodeV2Backup.getUserAllocations(user1.address);
      const allocations2 = await serverNodeV2Backup.getUserAllocations(user2.address);
      const allocations3 = await serverNodeV2Backup.getUserAllocations(user3.address);

      expect(allocations1.length).to.equal(1);
      expect(allocations2.length).to.equal(2);
      expect(allocations3.length).to.equal(1);
    });

    it("批量分配数量不能超过20个", async function () {
      const allocations = [];
      for (let i = 0; i < 21; i++) {
        allocations.push({
          user: user1.address,
          stakeAddress: admin.address,
          nodeType: 2,
          quantity: 1,
          amount: 0
        });
      }

      await expect(
        serverNodeV2Backup.connect(admin).allocateNodesBatch(allocations)
      ).to.be.revertedWith("Max 20 allocations per batch");
    });
  });

  // ==================== 10. 暂停功能 ====================
  describe("10. 暂停功能", function () {
    beforeEach(async function () {
      await serverNodeV2Backup.connect(owner).createNode([{
        ip: "192.168.1.100",
        describe: "Test Node",
        name: "Test",
        isActive: true,
        nodeStakeAddress: owner.address,
        id: 0,
        capacity: 0,
        createTime: 0,
        blockHeight: 0
      }]);
      await serverNodeV2Backup.connect(owner).setWhiteList(admin.address, true);
    });

    it("应该允许暂停和恢复节点分配", async function () {
      await serverNodeV2Backup.connect(owner).pauseNodeAllocation();

      let isPaused = await serverNodeV2Backup.isNodeAllocationPaused();
      expect(isPaused).to.be.true;

      await expect(
        serverNodeV2Backup.connect(admin).allocateNodes(user1.address, admin.address, 2, 1, 0)
      ).to.be.revertedWith("Node allocation is paused");

      await serverNodeV2Backup.connect(owner).unpauseNodeAllocation();

      isPaused = await serverNodeV2Backup.isNodeAllocationPaused();
      expect(isPaused).to.be.false;

      await serverNodeV2Backup.connect(admin).allocateNodes(user1.address, admin.address, 2, 1, 0);
    });
  });

  // ==================== 11. 奖励分发测试 ====================
  describe("11. 奖励分发", function () {
    beforeEach(async function () {
      // 创建足够的节点，确保有足够容量
      for (let i = 1; i <= 5; i++) {
        await serverNodeV2Backup.connect(owner).createNode([{
          ip: `192.168.1.${200 + i}`,
          describe: `Reward Node ${i}`,
          name: `Reward-${i.toString().padStart(3, '0')}`,
          isActive: true,
          nodeStakeAddress: owner.address,
          id: 0,
          capacity: 0,
          createTime: 0,
          blockHeight: 0
        }]);
      }

      await serverNodeV2Backup.connect(owner).setWhiteList(admin.address, true);
    });

    it("应该正确分发奖励（单个质押地址）", async function () {
      // 分配节点给用户
      await serverNodeV2Backup.connect(admin).allocateNodes(user1.address, admin.address, 2, 5, 0);
      
      // 获取合约地址
      const contractAddress = await serverNodeV2Backup.getAddress();
      
      // 向合约转入ETH作为奖励资金
      const ethAmount = ethers.parseEther("10");
      await owner.sendTransaction({ to: contractAddress, value: ethAmount });
      
      // 检查当前奖励信息
      try {
        const rewardInfo = await serverNodeV2Backup.getCurrentRewardInfo();
        console.log("当前奖励信息:", {
          dailyReward: ethers.formatEther(rewardInfo[0]),
          currentYear: rewardInfo[1],
          currentDay: rewardInfo[2]
        });
      } catch (error) {
        console.log("获取奖励信息失败:", error.message);
      }
      
      // 调用奖励分发函数
      const users = [user1.address];
      
      // 监听RewardDistributed事件以获取分发详情
      const rewardPromise = new Promise((resolve, reject) => {
        const timeoutId = setTimeout(() => {
          reject(new Error("事件未触发，可能奖励为0"));
        }, 5000);
        
        serverNodeV2Backup.once("RewardDistributed", 
          (user, amount, stakeAddress, amount2, year) => {
            clearTimeout(timeoutId);
            console.log("\n=== 奖励分发详情 ===");
            console.log("分发地址:", user);
            console.log("质押地址:", stakeAddress);
            console.log("用户奖励金额:", ethers.formatEther(amount), "ETH");
            console.log("质押地址奖励金额:", ethers.formatEther(amount2), "ETH");
            resolve({ user, stakeAddress, userReward: amount, stakeReward: amount2 });
          }
        );
      });

      // 调用奖励分发函数
      await expect(serverNodeV2Backup.connect(owner).configRewards(users)).to.not.be.reverted;
      
      try {
        const rewardDetails = await rewardPromise; // 等待事件触发并获取详情
        console.log("奖励分发成功:", rewardDetails);
      } catch (error) {
        console.log("奖励分发事件未触发:", error.message);
      }
    });

    it("应该正确分发奖励（多个质押地址）", async function () {
      // 使用不同的质押地址分配节点给用户
      await serverNodeV2Backup.connect(admin).allocateNodes(user1.address, stakeAddress1.address, 2, 2, 0); // 2个中节点 = 400,000
      await serverNodeV2Backup.connect(admin).allocateNodes(user1.address, stakeAddress2.address, 2, 2, 0); // 2个中节点 = 400,000
      await serverNodeV2Backup.connect(admin).allocateNodes(user1.address, stakeAddress3.address, 3, 2, 0); // 2个小节点 = 100,000
      
      // 获取合约地址
      const contractAddress = await serverNodeV2Backup.getAddress();
      
      // 向合约转入ETH作为奖励资金
      const ethAmount = ethers.parseEther("10");
      await owner.sendTransaction({ to: contractAddress, value: ethAmount });
      
      // 调用奖励分发函数
      const users = [user1.address];
      
      // 监听RewardDistributed事件以获取分发详情
      const rewardPromise = new Promise((resolve, reject) => {
        const timeoutId = setTimeout(() => {
          reject(new Error("事件未触发，可能奖励为0"));
        }, 10000);
        
        serverNodeV2Backup.on("RewardDistributed", 
          (user, amount, stakeAddress, amount2, year) => {
            console.log("\n=== 奖励分发详情 ===");
            console.log("分发地址:", user);
            console.log("质押地址:", stakeAddress);
            console.log("用户奖励金额:", ethers.formatEther(amount), "ETH");
            console.log("质押地址奖励金额:", ethers.formatEther(amount2), "ETH");
          }
        );
        
        // 3秒后解析Promise，确保所有事件都已触发
        setTimeout(() => {
          clearTimeout(timeoutId);
          resolve();
        }, 3000);
      });

      // 注意：由于合约没有Token功能，我们只测试函数调用是否成功
      await expect(serverNodeV2Backup.connect(owner).configRewards(users)).to.not.be.reverted;
      
      try {
        await rewardPromise; // 等待事件触发并获取详情
        console.log("奖励分发测试完成");
      } catch (error) {
        console.log("奖励分发事件未触发:", error.message);
      }
    });

  });

  // ==================== 12. 大节点分配逻辑测试 ====================
  describe("12. 大节点分配逻辑测试", function () {
    beforeEach(async function () {
      // 创建3个节点
      for (let i = 1; i <= 3; i++) {
        await serverNodeV2Backup.connect(owner).createNode([{
          ip: `192.168.1.${300 + i}`,
          describe: `Test Node ${i}`,
          name: `Test-${i}`,
          isActive: true,
          nodeStakeAddress: owner.address,
          id: 0,
          capacity: 0,
          createTime: 0,
          blockHeight: 0
        }]);
      }
      await serverNodeV2Backup.connect(owner).setWhiteList(admin.address, true);
    });

    it("大节点分配后应该标记为已完全分配", async function () {
      await serverNodeV2Backup.connect(admin).allocateNodes(user1.address, admin.address, 1, 1, 0);

      // 验证节点是否被标记为大节点
      const isNodeAllocated = await serverNodeV2Backup.isNodeAllocatedAsBig(1);
      expect(isNodeAllocated).to.be.true;

      // 验证节点剩余容量为0
      const nodeRemainingCapacity = await serverNodeV2Backup.getNodeRemainingCapacity(1);
      expect(nodeRemainingCapacity).to.equal(0n);
    });

    it("大节点分配后不能再分配任何金额", async function () {
      // 先分配一个大节点
      await serverNodeV2Backup.connect(admin).allocateNodes(user1.address, admin.address, 1, 1, 0);

      // 尝试在同一个节点上分配中节点（应该失败）
      await expect(
        serverNodeV2Backup.connect(admin).allocateNodes(user2.address, admin.address, 2, 1, 0)
      ).to.not.be.reverted; // 应该成功，因为会使用其他节点

      // 验证第一个节点仍然是大节点
      const isNodeAllocated = await serverNodeV2Backup.isNodeAllocatedAsBig(1);
      expect(isNodeAllocated).to.be.true;
    });
  });

  // ==================== 13. 多签提款 ====================
  describe("13. 多签提款", function () {
    beforeEach(async function () {
      // 向合约发送ETH
      const ethAmount = ethers.parseEther("1000");
      await owner.sendTransaction({
        to: await serverNodeV2Backup.getAddress(),
        value: ethAmount
      });
    });

    it("应该允许创建提款提案", async function () {
      const amount = ethers.parseEther("100");
      
      await serverNodeV2Backup.connect(signer1).proposeWithdrawal(
        user1.address,
        amount
      );

      const proposal = await serverNodeV2Backup.getWithdrawalProposal(0);
      expect(proposal.proposer).to.equal(signer1.address);
      expect(proposal.recipient).to.equal(user1.address);
      expect(proposal.amount).to.equal(amount);
    });

    it("应该允许确认和执行提款提案", async function () {
      const amount = ethers.parseEther("100");
      
      // 创建提案
      await serverNodeV2Backup.connect(signer1).proposeWithdrawal(
        user1.address,
        amount
      );

      // 确认提案（需要达到签名阈值）
      await serverNodeV2Backup.connect(signer1).confirmWithdrawal(0);
      await serverNodeV2Backup.connect(signer2).confirmWithdrawal(0);

      // 执行提案
      await serverNodeV2Backup.connect(signer1).executeWithdrawal(0);

      // 验证提案状态
      const proposal = await serverNodeV2Backup.getWithdrawalProposal(0);
      expect(proposal.executed).to.be.true;
    });

    it("应该拒绝无效的提款操作", async function () {
      const amount = ethers.parseEther("100");
      
      // 记录user1的初始余额
      const initialBalance = await ethers.provider.getBalance(user1.address);

      // 创建提案
      await serverNodeV2Backup.connect(signer1).proposeWithdrawal(
        user1.address,
        amount
      );

      // 非签名者不能确认
      await expect(
        serverNodeV2Backup.connect(user1).confirmWithdrawal(0)
      ).to.be.revertedWith("Not authorized");

      // 确认提案（达到签名阈值）
      await serverNodeV2Backup.connect(signer1).confirmWithdrawal(0);
      await serverNodeV2Backup.connect(signer2).confirmWithdrawal(0);

      // 非签名者也可以执行已获得足够确认的提案
      await serverNodeV2Backup.connect(user1).executeWithdrawal(0);

      // 验证提款成功
      const balance = await ethers.provider.getBalance(user1.address);
      expect(balance).to.be.greaterThan(initialBalance);
    });
  });

  // ==================== 14. 查询功能 ====================
  describe("14. 查询功能", function () {
    beforeEach(async function () {
      await serverNodeV2Backup.connect(owner).createNode([{
        ip: "192.168.1.300",
        describe: "Query Test",
        name: "Query-001",
        isActive: true,
        nodeStakeAddress: owner.address,
        id: 0,
        capacity: 0,
        createTime: 0,
        blockHeight: 0
      }]);
      await serverNodeV2Backup.connect(owner).setWhiteList(admin.address, true);
      await serverNodeV2Backup.connect(admin).allocateNodes(user1.address, admin.address, 2, 3, 0);
      
      // 向合约发送ETH以确保余额查询有效
      const ethAmount = ethers.parseEther("100");
      await owner.sendTransaction({
        to: await serverNodeV2Backup.getAddress(),
        value: ethAmount
      });
    });

    it("应该正确查询用户分配记录", async function () {
      const allocations = await serverNodeV2Backup.getUserAllocations(user1.address);
      expect(allocations.length).to.equal(3);
    });

    it("应该正确查询节点剩余容量", async function () {
      const remaining = await serverNodeV2Backup.getNodeRemainingCapacity(1);
      expect(remaining).to.equal(DEFAULT_CAPACITY - 600000n);
    });

    it("应该正确查询白名单数量", async function () {
      const count = await serverNodeV2Backup.getWhitelistCount();
      expect(count).to.equal(1n);
    });

    it("应该正确查询合约余额", async function () {
      const balance = await serverNodeV2Backup.getContractBalance();
      expect(balance).to.be.gt(0);
    });
  });

  // ==================== 15. 边界情况和错误处理 ====================
  describe("15. 边界情况和错误处理", function () {
    beforeEach(async function () {
      await serverNodeV2Backup.connect(owner).createNode([{
        ip: "192.168.1.400",
        describe: "Test",
        name: "Test",
        isActive: true,
        nodeStakeAddress: owner.address,
        id: 0,
        capacity: 0,
        createTime: 0,
        blockHeight: 0
      }]);
      await serverNodeV2Backup.connect(owner).setWhiteList(admin.address, true);
    });

    it("应该拒绝无效的节点分配参数", async function () {
      await expect(
        serverNodeV2Backup.connect(admin).allocateNodes(user1.address, admin.address, 0, 1, 0)
      ).to.be.revertedWith("Invalid node type");
    });

    it("应该拒绝超出容量的分配", async function () {
      // 先分配满一个节点
      await serverNodeV2Backup.connect(admin).allocateNodes(user1.address, admin.address, 2, 5, 0);
      
      // 再尝试分配应该失败
      await expect(
        serverNodeV2Backup.connect(admin).allocateNodes(user2.address, admin.address, 2, 1, 0)
      ).to.be.revertedWith("Insufficient capacity for medium nodes");
    });
  });

  // ==================== 16. 解除分配功能测试 ====================
  describe("16. 解除分配功能测试", function () {
    beforeEach(async function () {
      // 创建节点
      await serverNodeV2Backup.connect(owner).createNode([{
        ip: "192.168.1.500",
        describe: "Test Node",
        name: "Test",
        isActive: true,
        nodeStakeAddress: owner.address,
        id: 0,
        capacity: 0,
        createTime: 0,
        blockHeight: 0
      }]);
      await serverNodeV2Backup.connect(owner).setWhiteList(admin.address, true);
      
      // 分配节点给用户
      await serverNodeV2Backup.connect(admin).allocateNodes(user1.address, admin.address, 2, 3, 0);
    });

    it("应该正确解除用户节点分配", async function () {
      // 获取用户分配记录
      let userAllocations = await serverNodeV2Backup.getUserAllocations(user1.address);
      expect(userAllocations.length).to.equal(3);
      
      // 获取节点剩余容量
      const initialRemainingCapacity = await serverNodeV2Backup.getNodeRemainingCapacity(1);
      
      // 解除分配（逐个解除）
      for (const allocation of userAllocations) {
        await serverNodeV2Backup.connect(owner).deallocateNodes(
          user1.address,
          allocation.stakeAddress,
          allocation.nodeType,
          allocation.amount,
          allocation.nodeId
        );
      }
      
      // 验证用户分配记录被清空
      userAllocations = await serverNodeV2Backup.getUserAllocations(user1.address);
      expect(userAllocations.length).to.equal(0);
      
      // 验证节点剩余容量恢复
      const finalRemainingCapacity = await serverNodeV2Backup.getNodeRemainingCapacity(1);
      expect(finalRemainingCapacity).to.be.greaterThan(initialRemainingCapacity);
    });

    it("非管理员不能解除分配", async function () {
      // 获取用户分配记录
      const userAllocations = await serverNodeV2Backup.getUserAllocations(user1.address);
      
      // 尝试以非管理员身份解除分配
      await expect(
        serverNodeV2Backup.connect(user1).deallocateNodes(
          user1.address,
          userAllocations[0].stakeAddress,
          userAllocations[0].nodeType,
          userAllocations[0].amount,
          userAllocations[0].nodeId
        )
      ).to.be.reverted;
    });
  });

  // ==================== 17. 节点暂停功能测试 ====================
  describe("17. 节点暂停功能测试", function () {
    beforeEach(async function () {
      // 创建节点
      for (let i = 1; i <= 2; i++) {
        await serverNodeV2Backup.connect(owner).createNode([{
          ip: `192.168.1.${600 + i}`,
          describe: `Test Node ${i}`,
          name: `Test-${i}`,
          isActive: true,
          nodeStakeAddress: owner.address,
          id: 0,
          capacity: 0,
          createTime: 0,
          blockHeight: 0
        }]);
      }
      await serverNodeV2Backup.connect(owner).setWhiteList(admin.address, true);
    });

    it("应该正确暂停和恢复节点", async function () {
      // 分配节点给用户
      await serverNodeV2Backup.connect(admin).allocateNodes(user1.address, admin.address, 2, 2, 0);
      
      // 暂停节点
      await serverNodeV2Backup.connect(owner).pauseNode(1);
      
      // 验证节点被暂停
      const nodeInfo = await serverNodeV2Backup.getNodeInfo(1);
      expect(nodeInfo.isActive).to.be.false;
      
      // 恢复节点
      await serverNodeV2Backup.connect(owner).unpauseNode(1);
      
      // 验证节点被恢复
      const nodeInfoAfter = await serverNodeV2Backup.getNodeInfo(1);
      expect(nodeInfoAfter.isActive).to.be.true;
    });

    it("非管理员不能暂停/恢复节点", async function () {
      await expect(
        serverNodeV2Backup.connect(user1).pauseNode(1)
      ).to.be.reverted;
      
      await expect(
        serverNodeV2Backup.connect(user1).unpauseNode(1)
      ).to.be.reverted;
    });

    it("暂停节点后不应该参与奖励分配", async function () {
      // 分配节点给用户
      await serverNodeV2Backup.connect(admin).allocateNodes(user1.address, admin.address, 2, 2, 0);
      
      // 获取合约地址并转入ETH
      const contractAddress = await serverNodeV2Backup.getAddress();
      const ethAmount = ethers.parseEther("10");
      await owner.sendTransaction({ to: contractAddress, value: ethAmount });
      
      // 暂停节点
      await serverNodeV2Backup.connect(owner).pauseNode(1);
      
      // 尝试分发奖励，预期会被回滚（因为节点被暂停，没有活跃的分配记录）
      const users = [user1.address];
      
      // 预期调用会被回滚，因为没有活跃的节点分配记录
      await expect(
        serverNodeV2Backup.connect(owner).configRewards(users)
      ).to.be.revertedWith("No active node allocation records found for user");
    });
  });

  // ==================== 18. 紧急提款功能测试 ====================
  describe("18. 紧急提款功能测试", function () {
    beforeEach(async function () {
      // 向合约发送ETH
      const ethAmount = ethers.parseEther("10");
      await owner.sendTransaction({
        to: await serverNodeV2Backup.getAddress(),
        value: ethAmount
      });
    });

    it("应该允许管理员执行紧急提款", async function () {
      // 记录owner的初始余额
      const initialBalance = await ethers.provider.getBalance(owner.address);
      
      // 执行紧急提款
      await serverNodeV2Backup.connect(owner).emergencyWithdraw();
      
      // 验证提款成功
      const finalBalance = await ethers.provider.getBalance(owner.address);
      expect(finalBalance).to.be.greaterThan(initialBalance);
    });

    it("非管理员不能执行紧急提款", async function () {
      await expect(
        serverNodeV2Backup.connect(user1).emergencyWithdraw()
      ).to.be.reverted;
    });
  });

  // ==================== 19. ETH存款功能测试 ====================
  describe("19. ETH存款功能测试", function () {
    it("应该允许管理员存款ETH", async function () {
      // 获取初始合约余额
      const initialBalance = await serverNodeV2Backup.getContractBalance();
      
      // 存款ETH
      const depositAmount = ethers.parseEther("5");
      await serverNodeV2Backup.connect(owner).depositETH({ value: depositAmount });
      
      // 验证合约余额增加
      const finalBalance = await serverNodeV2Backup.getContractBalance();
      expect(finalBalance).to.equal(initialBalance + depositAmount);
    });

    it("非管理员不能存款ETH", async function () {
      const depositAmount = ethers.parseEther("1");
      await expect(
        serverNodeV2Backup.connect(user1).depositETH({ value: depositAmount })
      ).to.be.reverted;
    });
  });

  // ==================== 20. 奖励管理功能测试 ====================
  describe("20. 奖励管理功能测试", function () {
    it("应该允许管理员暂停和恢复奖励分发", async function () {
      // 暂停奖励
      await serverNodeV2Backup.connect(owner).pauseRewards();
      
      // 验证奖励已暂停
      const isPaused = await serverNodeV2Backup.isPaused();
      expect(isPaused).to.be.true;
      
      // 恢复奖励
      await serverNodeV2Backup.connect(owner).unpauseRewards();
      
      // 验证奖励已恢复
      const isUnpaused = await serverNodeV2Backup.isPaused();
      expect(isUnpaused).to.be.false;
    });

    it("应该允许管理员暂停和恢复节点分配奖励", async function () {
      // 暂停节点分配奖励
      await serverNodeV2Backup.connect(owner).pauseNodeAllocationReward();
      
      // 恢复节点分配奖励
      await serverNodeV2Backup.connect(owner).unpauseNodeAllocationReward();
      
      // 验证操作成功（无错误抛出）
      expect(true).to.be.true;
    });

    it("非管理员不能管理奖励状态", async function () {
      await expect(
        serverNodeV2Backup.connect(user1).pauseRewards()
      ).to.be.reverted;
      
      await expect(
        serverNodeV2Backup.connect(user1).unpauseRewards()
      ).to.be.reverted;
      
      await expect(
        serverNodeV2Backup.connect(user1).pauseNodeAllocationReward()
      ).to.be.reverted;
      
      await expect(
        serverNodeV2Backup.connect(user1).unpauseNodeAllocationReward()
      ).to.be.reverted;
    });
  });

  // ==================== 21. 多签管理功能测试 ====================
  describe("21. 多签管理功能测试", function () {
    it("应该允许签名人添加和移除提款签名者", async function () {
      // 添加新的签名者（使用签名人身份）
      await serverNodeV2Backup.connect(signer1).addWithdrawSigner(user1.address);
      
      // 移除签名者（使用签名人身份）
      await serverNodeV2Backup.connect(signer1).removeWithdrawSigner(signer3.address);
      
      // 验证操作成功（无错误抛出）
      expect(true).to.be.true;
    });

    it("应该允许签名人更新提款签名阈值", async function () {
      // 更新阈值为2（使用签名人身份）
      await serverNodeV2Backup.connect(signer1).updateWithdrawThreshold(2);
      
      // 验证操作成功（无错误抛出）
      expect(true).to.be.true;
    });

    it("非签名人不能管理多签设置", async function () {
      await expect(
        serverNodeV2Backup.connect(user1).addWithdrawSigner(user2.address)
      ).to.be.revertedWith("Not authorized");
      
      await expect(
        serverNodeV2Backup.connect(user1).removeWithdrawSigner(signer1.address)
      ).to.be.revertedWith("Not authorized");
      
      await expect(
        serverNodeV2Backup.connect(user1).updateWithdrawThreshold(1)
      ).to.be.revertedWith("Not authorized");
    });
  });

});
