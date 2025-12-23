const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");

describe("MonadProjectBackup", function () {
  let ERC20Mock;
  let contract, rewardCalculator, bkcToken;
  let owner, user1, user2, signer1, signer2, signer3;

  beforeEach(async function () {
    [owner, user1, user2, signer1, signer2, signer3] = await ethers.getSigners();

    // 部署模拟 BKC 代币
    ERC20Mock = await ethers.getContractFactory("ERC20Mock");
    bkcToken = await ERC20Mock.deploy("BKC Token", "BKC", ethers.parseEther("1000000"));

     // 铸造bkc
    await bkcToken.mint(rewardCalculator.target, ethers.parseEther("500000"));

    // 部署 DecreasingRewardCalculator Mock
    const RewardCalculator = await ethers.getContractFactory("DecreasingRewardCalculator");
    rewardCalculator = await RewardCalculator.deploy();

    // 部署 MonadProjectBackup
    const MonadProjectBackupFactory = await ethers.getContractFactory("MonadProjectBackup");
    contract = await upgrades.deployProxy(MonadProjectBackupFactory, [
      owner.address,
      rewardCalculator.target,
      [signer1.address, signer2.address, signer3.address],
      2 // threshold
    ], { initializer: 'initialize' });

    // 给合约转一些 BKC
    await bkcToken.transfer(contract.target, ethers.parseEther("10000"));

    // 设置 BKC 地址
    await contract.setBKC(bkcToken.target);
  });

  describe("Initialization", function () {
    it("Should initialize correctly", async function () {
      expect(await contract.owner()).to.equal(owner.address);
      expect(await contract.REWARD()).to.equal(rewardCalculator.target);
      expect(await contract.opThreshold()).to.equal(2);
      expect(await contract.withdrawThreshold()).to.equal(2);
    });

  describe("MultiSig Management", function () {
    it("Should add operation signer", async function () {
      await contract.connect(signer1).addOpSigner(user1.address);
      expect(await contract.isOpSigner(user1.address)).to.be.true;
    });

    it("Should remove operation signer", async function () {
      await contract.connect(signer1).removeOpSigner(signer3.address);
      expect(await contract.isOpSigner(signer3.address)).to.be.false;
    });

    it("Should update operation threshold", async function () {
      await contract.connect(signer1).updateOpThreshold(3);
      expect(await contract.opThreshold()).to.equal(3);
    });
  });

  describe("Node Management", function () {
    it("Should create node", async function () {
      const nodeInfo = [{
        ip: "192.168.1.1",
        describe: "Test Node",
        name: "Node1",
        isActive: true,
        typeParam: 1,
        id: 0,
        capacity: 100,
        createTime: 0,
        blockHeight: 0
      }];

    it("Should configure node", async function () {
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
      expect(await contract.userPhysicalNodes(owner.address)).to.equal(1);
      expect(await contract.totalPhysicalNodes()).to.equal(1);
    });

    it("Should reject invalid node type", async function () {
      const configParams = [{
        stakeAddress: user1.address,
        isActive: true,
        typeParam: 5, // Invalid type
        id: 1,
        nodeCapacity: 100,
        nodeMoney: 0,
        createTime: 0,
        blockHeight: 0
      }];

      await expect(contract.connect(owner).configNode(configParams)).to.be.revertedWith("Invalid node type");
    });

    it("Should reject duplicate node ID", async function () {
      const configParams1 = [{
        stakeAddress: user1.address,
        isActive: true,
        typeParam: 1,
        id: 1,
        nodeCapacity: 100,
        nodeMoney: 0,
        createTime: 0,
        blockHeight: 0
      }];

      const configParams2 = [{
        stakeAddress: user2.address,
        isActive: true,
        typeParam: 1,
        id: 1, // Same ID
        nodeCapacity: 100,
        nodeMoney: 0,
        createTime: 0,
        blockHeight: 0
      }];

      await contract.connect(owner).configNode(configParams1);
      await expect(contract.connect(owner).configNode(configParams2)).to.be.revertedWith("Node ID already exists");
    });
  });

  describe("Reward Distribution", function () {
    beforeEach(async function () {
      // Setup a node for user1
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
    });

    it("Should distribute rewards", async function () {
      // Set user1 as whitelist and config a node for user1
      await contract.connect(signer1).setWhiteList(user1.address, true);
      const configParams = [{
        stakeAddress: user1.address,
        isActive: true,
        typeParam: 1,
        id: 200,
        nodeCapacity: 100,
        nodeMoney: 0,
        createTime: 0,
        blockHeight: 0
      }];
      await contract.connect(user1).configNode(configParams);

      // Note: In a real test, you would need to ensure the contract has BKC tokens
      // For this mock test, we assume the contract has sufficient balance
      await expect(contract.connect(owner).configRewards(user1.address, 1))
        .to.emit(contract, "RewardDistributed");
      expect(await contract.hasRewarded(user1.address, 1)).to.be.true;
    });

    it("Should reject invalid year", async function () {
      await expect(contract.connect(owner).configRewards(user1.address, 0)).to.be.revertedWith("Invalid year");
    });

    it("Should enforce 24-hour cooldown", async function () {
      // Set user1 as whitelist and config a node for user1
      await contract.connect(signer1).setWhiteList(user1.address, true);
      const configParams = [{
        stakeAddress: user1.address,
        isActive: true,
        typeParam: 1,
        id: 3,
        nodeCapacity: 100,
        nodeMoney: 0,
        createTime: 0,
        blockHeight: 0
      }];
      await contract.connect(user1).configNode(configParams);

      await contract.connect(owner).configRewards(user1.address, 1);
      await expect(contract.connect(owner).configRewards(user1.address, 1)).to.be.revertedWith("User already rewarded this year or within 24 hours");
    });

    it("Should reject when paused", async function () {      // Set user1 as whitelist and config a node for user1
      await contract.connect(signer1).setWhiteList(user1.address, true);
      const configParams = [{
        stakeAddress: user1.address,
        isActive: true,
        typeParam: 1,
        id: 4,
        nodeCapacity: 100,
        nodeMoney: 0,
        createTime: 0,
        blockHeight: 0
      }];
      await contract.connect(user1).configNode(configParams);
      await contract.connect(signer1).pauseRewards();
      await expect(contract.connect(owner).configRewards(user1.address, 1)).to.be.reverted;
    });
  });

  describe("Withdrawal Management", function () {
    it("Should propose withdrawal", async function () {
      const amount = ethers.parseEther("100");
      await contract.connect(signer1).proposeWithdrawal(bkcToken.target, user1.address, amount);
      const proposal = await contract.getWithdrawalProposal(0);
      expect(proposal.amount).to.equal(amount);
      expect(proposal.executed).to.be.false;
    });

    it("Should confirm and execute withdrawal", async function () {
      const amount = ethers.parseEther("100");
      await contract.connect(signer1).proposeWithdrawal(bkcToken.target, user1.address, amount);
      await contract.connect(signer2).confirmWithdrawal(0);
      await contract.connect(signer3).confirmWithdrawal(0);

      const initialBalance = await bkcToken.balanceOf(user1.address);
      await contract.connect(signer1).executeWithdrawal(0);
      const finalBalance = await bkcToken.balanceOf(user1.address);

      expect(finalBalance - initialBalance).to.equal(amount);
    });

    it("Should reject execution without enough confirmations", async function () {
      const amount = ethers.parseEther("100");
      await contract.connect(signer1).proposeWithdrawal(bkcToken.target, user1.address, amount);
      await expect(contract.connect(signer1).executeWithdrawal(0)).to.be.revertedWith("Not enough confirmations");
    });
  });

  describe("Whitelist Management", function () {
    it("Should set whitelist", async function () {
      await contract.connect(signer1).setWhiteList(user1.address, true);
      expect(await contract.whiteList(user1.address)).to.be.true;
    });
  });
});

  describe("Pause/Unpause", function () {
    it("Should pause and unpause rewards", async function () {
      await contract.connect(signer1).pauseRewards();
      expect(await contract.isPaused()).to.be.true;

      await contract.connect(signer1).unpauseRewards();
      expect(await contract.isPaused()).to.be.false;
    });
  });

  describe("View Functions", function () {
    it("Should check state consistency", async function () {
      expect(await contract.checkStateConsistency()).to.be.true;
    });

    it("Should get config node info", async function () {
      const configParams = [{
        stakeAddress: owner.address,
        isActive: true,
        typeParam: 1,
        id: 5,
        nodeCapacity: 100,
        nodeMoney: 0,
        createTime: 0,
        blockHeight: 0
      }];
      await contract.connect(owner).configNode(configParams);

      const nodes = await contract.getConfigNodeInfo(owner.address, 5, 5);
      expect(nodes.length).to.equal(1);
      expect(nodes[0].id).to.equal(5);
    });
  });
});
});