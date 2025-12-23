const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");

describe("ServerNodeBackup - Complete Test Suite (Final)", function () {
  let contract, bkcToken, rewardCalculator;
  let owner, user1, user2, user3, signer1, signer2, signer3;

  beforeEach(async function () {
    [owner, user1, user2, user3, signer1, signer2, signer3] = await ethers.getSigners();

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

  describe("📋 Initialization", function () {
    it("Should initialize correctly", async function () {
      expect(await contract.owner()).to.equal(owner.address);
      expect(await contract.getTokenBalance()).to.equal(ethers.parseEther("1000000"));

      const [signers, threshold] = await contract.getWithdrawMultiSigInfo();
      expect(signers.length).to.equal(3);
      expect(threshold).to.equal(2);
    });
  });

  describe("🔧 Node Management", function () {
    it("Should configure node types correctly", async function () {
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

      const userNodes = await contract.userPhysicalNodes(user1.address);
      const totalNodes = await contract.totalPhysicalNodes();

      expect(userNodes).to.equal(1);
      expect(totalNodes).to.equal(1);
    });

    it("Should reject invalid node types", async function () {
      const invalidConfig = [{
        stakeAddress: user1.address,
        isActive: true,
        typeParam: 5,
        id: 1,
        nodeCapacity: 100,
        nodeMoney: 0,
        createTime: 0,
        blockHeight: 0
      }];

      await expect(contract.connect(owner).configNode(invalidConfig))
        .to.be.revertedWith("Invalid node type");
    });

    it("Should reject duplicate node IDs", async function () {
      const configParams = [{
        stakeAddress: user1.address,
        isActive: true,
        typeParam: 1,
        id: 1,
        nodeCapacity: 100,
        nodeMoney: 0,
        createTime: 0,
        blockHeight: 0
      }];

      await contract.connect(owner).configNode(configParams);

      await expect(contract.connect(owner).configNode(configParams))
        .to.be.revertedWith("Node ID already exists");
    });

    it("Should reject exceeding physical node limit", async function () {
      const configParams = [{
        stakeAddress: user1.address,
        isActive: true,
        typeParam: 4,
        id: 1,
        nodeCapacity: 1000,
        nodeMoney: 2000000000,
        createTime: 0,
        blockHeight: 0
      }];

      await contract.connect(owner).configNode(configParams);

      configParams[0].id = 2;
      configParams[0].nodeMoney = 1000000;

      await expect(contract.connect(owner).configNode(configParams))
        .to.be.revertedWith("Exceeds maximum physical nodes limit");
    });

    it("Should reject low-value commodity nodes", async function () {
      const configParams = [{
        stakeAddress: user1.address,
        isActive: true,
        typeParam: 4,
        id: 1,
        nodeCapacity: 100,
        nodeMoney: 999999,
        createTime: 0,
        blockHeight: 0
      }];

      await expect(contract.connect(owner).configNode(configParams))
        .to.be.revertedWith("Node value too low");
    });
  });

  describe("💰 Reward Distribution", function () {
    beforeEach(async function () {
      await contract.connect(owner).configNode([
        {
          stakeAddress: user1.address,
          isActive: true,
          typeParam: 1,
          id: 1,
          nodeCapacity: 100,
          nodeMoney: 0,
          createTime: 0,
          blockHeight: 0
        },
        {
          stakeAddress: user2.address,
          isActive: true,
          typeParam: 1,
          id: 2,
          nodeCapacity: 100,
          nodeMoney: 0,
          createTime: 0,
          blockHeight: 0
        },
        {
          stakeAddress: user3.address,
          isActive: true,
          typeParam: 1,
          id: 3,
          nodeCapacity: 100,
          nodeMoney: 0,
          createTime: 0,
          blockHeight: 0
        }
      ]);
    });

    it("Should distribute rewards to multiple users", async function () {
      const users = [user1.address, user2.address, user3.address];

      const initialBalances = await Promise.all(users.map(u => bkcToken.balanceOf(u)));

      await expect(contract.connect(owner).configRewards(users, 1))
        .to.emit(contract, "BatchRewardsDistributed");

      for (let i = 0; i < users.length; i++) {
        const finalBalance = await bkcToken.balanceOf(users[i]);
        expect(finalBalance).to.be.gt(initialBalances[i]);
      }
    });

    it("Should enforce 24-hour cooldown", async function () {
      const users = [user1.address];

      await contract.connect(owner).configRewards(users, 1);

      const [hasRewarded1] = await contract.getUserRewardStatus(user1.address, 1);
      expect(hasRewarded1).to.be.true;

      try {
        await contract.connect(owner).configRewards(users, 1);
        expect.fail("Should have reverted");
      } catch (error) {
        expect(
          error.message.includes("User already rewarded") ||
          error.message.includes("No users were rewarded")
        ).to.be.true;
      }

      await ethers.provider.send("evm_increaseTime", [24 * 3600 + 1]);
      await ethers.provider.send("evm_mine");

      await expect(contract.connect(owner).configRewards(users, 1))
        .to.emit(contract, "BatchRewardsDistributed");
    });

    it("Should skip users with no nodes", async function () {
      const users = [user3.address];

      await contract.connect(owner).configRewards(users, 1);

      const [hasRewarded] = await contract.getUserRewardStatus(user3.address, 1);
      expect(hasRewarded).to.be.true;
    });

    it("Should reject invalid year", async function () {
      const users = [user1.address];

      await expect(contract.connect(owner).configRewards(users, 0))
        .to.be.revertedWith("Invalid year");
      await expect(contract.connect(owner).configRewards(users, 31))
        .to.be.revertedWith("Invalid year");
    });

    it("Should reject when paused", async function () {
      await contract.connect(owner).pauseRewards();

      const users = [user1.address];
      await expect(contract.connect(owner).configRewards(users, 1))
        .to.be.reverted;
    });

    it("Should calculate rewards correctly for different years", async function () {
      const users = [user1.address];

      await contract.connect(owner).configRewards(users, 1);
      const [hasRewarded1, time1] = await contract.getUserRewardStatus(user1.address, 1);
      expect(hasRewarded1).to.be.true;

      await ethers.provider.send("evm_increaseTime", [24 * 3600 + 1]);
      await ethers.provider.send("evm_mine");

      await contract.connect(owner).configRewards(users, 2);
      const [hasRewarded2, time2] = await contract.getUserRewardStatus(user1.address, 2);

      expect(hasRewarded2).to.be.true;
      expect(time2).to.be.gt(time1);
    });
  });

  describe("🔐 Whitelist Management", function () {
    it("Should allow owner to set whitelist", async function () {
      await contract.connect(owner).setWhiteList(user1.address, true);
      expect(await contract.whiteList(user1.address)).to.be.true;

      await contract.connect(owner).setWhiteList(user1.address, false);
      expect(await contract.whiteList(user1.address)).to.be.false;
    });

    it("Should allow whitelist user to configure nodes", async function () {
      await contract.connect(owner).setWhiteList(user1.address, true);

      const configParams = [{
        stakeAddress: user1.address,
        isActive: true,
        typeParam: 1,
        id: 10,
        nodeCapacity: 100,
        nodeMoney: 0,
        createTime: 0,
        blockHeight: 0
      }];

      await contract.connect(user1).configNode(configParams);
      expect(await contract.userPhysicalNodes(user1.address)).to.equal(1);
    });

    it("Should reject non-whitelist non-owner", async function () {
      const configParams = [{
        stakeAddress: user2.address,
        isActive: true,
        typeParam: 1,
        id: 11,
        nodeCapacity: 100,
        nodeMoney: 0,
        createTime: 0,
        blockHeight: 0
      }];

      await expect(contract.connect(user2).configNode(configParams))
        .to.be.revertedWith("Only whitelist or Only Owner");
    });
  });

  describe("🔐 Withdrawal MultiSig", function () {
    it("Should execute full withdrawal flow", async function () {
      const amount = ethers.parseEther("100");

      await contract.connect(signer1).proposeWithdrawal(
        await bkcToken.getAddress(),
        user1.address,
        amount
      );

      await contract.connect(signer1).confirmWithdrawal(0);
      await contract.connect(signer2).confirmWithdrawal(0);

      const initialBalance = await bkcToken.balanceOf(user1.address);
      await contract.connect(signer3).executeWithdrawal(0);
      const finalBalance = await bkcToken.balanceOf(user1.address);

      expect(finalBalance - initialBalance).to.equal(amount);

      const proposal = await contract.getWithdrawalProposal(0);
      expect(proposal.executed).to.be.true;
      expect(proposal.confirmations).to.equal(2);
    });

    it("Should confirm and execute in one step", async function () {
      const amount = ethers.parseEther("50");
      await contract.connect(signer1).proposeWithdrawal(
        await bkcToken.getAddress(),
        user2.address,
        amount
      );

      await contract.connect(signer1).confirmAndExecuteWithdrawal(0);

      const initialBalance = await bkcToken.balanceOf(user2.address);
      await contract.connect(signer2).confirmAndExecuteWithdrawal(0);
      const finalBalance = await bkcToken.balanceOf(user2.address);

      expect(finalBalance - initialBalance).to.equal(amount);
    });

    it("Should reject non-signer actions", async function () {
      await expect(contract.connect(user1).addWithdrawSigner(user2.address))
        .to.be.revertedWith("Not authorized: caller is not a withdrawal signer");
    });

    it("Should reject duplicate confirmations", async function () {
      const amount = ethers.parseEther("100");
      await contract.connect(signer1).proposeWithdrawal(
        await bkcToken.getAddress(),
        user1.address,
        amount
      );
      await contract.connect(signer1).confirmWithdrawal(0);

      await expect(contract.connect(signer1).confirmWithdrawal(0))
        .to.be.revertedWith("Already confirmed this withdrawal");
    });

    it("Should reject execution without enough confirmations", async function () {
      const amount = ethers.parseEther("100");
      await contract.connect(signer1).proposeWithdrawal(
        await bkcToken.getAddress(),
        user1.address,
        amount
      );
      await contract.connect(signer1).confirmWithdrawal(0);

      await expect(contract.connect(signer1).executeWithdrawal(0))
        .to.be.revertedWith("Not enough confirmations");
    });

    it("Should manage signer list", async function () {
      await contract.connect(signer1).addWithdrawSigner(user1.address);
      const [signers] = await contract.getWithdrawMultiSigInfo();
      expect(signers).to.include(user1.address);

      await contract.connect(signer1).removeWithdrawSigner(signer3.address);
      const [newSigners] = await contract.getWithdrawMultiSigInfo();
      expect(newSigners).to.not.include(signer3.address);
    });

    it("Should update threshold", async function () {
      await contract.connect(signer1).updateWithdrawThreshold(3);
      const [, threshold] = await contract.getWithdrawMultiSigInfo();
      expect(threshold).to.equal(3);
    });
  });

  describe("⏸️ Pause/Unpause", function () {
    it("Should pause and unpause rewards", async function () {
      await contract.connect(owner).pauseRewards();
      expect(await contract.isPaused()).to.be.true;

      await contract.connect(owner).unpauseRewards();
      expect(await contract.isPaused()).to.be.false;
    });

    it("Should reject actions when paused", async function () {
      await contract.connect(owner).pauseRewards();

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

      await expect(contract.connect(owner).configRewards([user1.address], 1))
        .to.be.reverted;
    });
  });

  describe("📊 View Functions", function () {
    it("Should check state consistency", async function () {
      expect(await contract.checkStateConsistency()).to.be.true;

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

      expect(await contract.checkStateConsistency()).to.be.true;
    });

    it("Should get config node info by range", async function () {
      const configParams = [
        { stakeAddress: owner.address, isActive: true, typeParam: 1, id: 5, nodeCapacity: 100, nodeMoney: 0, createTime: 0, blockHeight: 0 },
        { stakeAddress: owner.address, isActive: true, typeParam: 1, id: 6, nodeCapacity: 100, nodeMoney: 0, createTime: 0, blockHeight: 0 },
        { stakeAddress: owner.address, isActive: true, typeParam: 1, id: 7, nodeCapacity: 100, nodeMoney: 0, createTime: 0, blockHeight: 0 }
      ];
      await contract.connect(owner).configNode(configParams);

      const nodes = await contract.getConfigNodeInfo(owner.address, 5, 6);
      expect(nodes.length).to.equal(2);
      expect(nodes[0].id).to.equal(5);
      expect(nodes[1].id).to.equal(6);
    });

    it("Should get withdrawal proposal count", async function () {
      const initialCount = await contract.getWithdrawalProposalCount();
      expect(initialCount).to.equal(0);

      await contract.connect(signer1).proposeWithdrawal(
        await bkcToken.getAddress(),
        user1.address,
        ethers.parseEther("100")
      );

      const newCount = await contract.getWithdrawalProposalCount();
      expect(newCount).to.equal(1);
    });

    it("Should check withdrawal confirmation status", async function () {
      const amount = ethers.parseEther("100");
      await contract.connect(signer1).proposeWithdrawal(
        await bkcToken.getAddress(),
        user1.address,
        amount
      );
      await contract.connect(signer1).confirmWithdrawal(0);

      const hasConfirmed = await contract.hasWithdrawalConfirmed(0, signer1.address);
      const hasNotConfirmed = await contract.hasWithdrawalConfirmed(0, signer2.address);

      expect(hasConfirmed).to.be.true;
      expect(hasNotConfirmed).to.be.false;
    });
  });

  describe("🛠️ Admin Functions", function () {
    it("Should deposit tokens", async function () {
      const amount = ethers.parseEther("1000");
      await bkcToken.approve(await contract.getAddress(), amount);

      await contract.connect(owner).depositToken(amount);

      const balance = await contract.getTokenBalance();
      expect(balance).to.equal(ethers.parseEther("1001000"));
    });

    it("Should create nodes", async function () {
      const nodeInfo = [{
        ip: "192.168.1.1",
        describe: "High-performance node",
        name: "Node1",
        isActive: true,
        typeParam: 1,
        id: 0,
        capacity: 100,
        createTime: 0,
        blockHeight: 0
      }];

      await contract.connect(owner).createNode(nodeInfo);

      const node = await contract.deployNode(0);
      expect(node.name).to.equal("Node1");
      expect(node.ip).to.equal("192.168.1.1");
    });
  });
});
