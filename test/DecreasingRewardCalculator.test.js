const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("DecreasingRewardCalculator", function () {
  let Reward;
  let reward;
  let owner;

  const DAY = 86400;

  beforeEach(async function () {
    [owner] = await ethers.getSigners();

    Reward = await ethers.getContractFactory("DecreasingRewardCalculator");
    reward = await Reward.deploy();
    await reward.waitForDeployment();
  });

  /* -----------------------------------------------------------
   * constructor
   * --------------------------------------------------------- */
  describe("Constructor", function () {
    it("should set deploymentTimestamp", async function () {
      const ts = await reward.deploymentTimestamp();
      expect(ts).to.be.gt(0);
    });
  });

  /* -----------------------------------------------------------
   * getDaysSinceDeployment
   * --------------------------------------------------------- */
  describe("getDaysSinceDeployment", function () {
    it("returns day 1 immediately after deployment", async function () {
      expect(await reward.getDaysSinceDeployment()).to.equal(1);
    });

    it("returns correct day after 1 full day", async function () {
      await ethers.provider.send("evm_increaseTime", [DAY]);
      await ethers.provider.send("evm_mine");

      expect(await reward.getDaysSinceDeployment()).to.equal(1);
    });

    it("returns next day if partial day passed", async function () {
      await ethers.provider.send("evm_increaseTime", [DAY + 1]);
      await ethers.provider.send("evm_mine");

      expect(await reward.getDaysSinceDeployment()).to.equal(2);
    });
  });

  /* -----------------------------------------------------------
   * getDailyReward
   * --------------------------------------------------------- */
  describe("getDailyReward", function () {
    it("reverts if day is zero", async function () {
      await expect(reward.getDailyReward(0)).to.be.revertedWith(
        "Day must be positive"
      );
    });

    it("year 1 returns initial reward", async function () {
      const r = await reward.getDailyReward(1);
      expect(r).to.equal(1);
    });

    it("year 2 reward is decreased by 10%", async function () {
      const day = 366; // first day of year 2
      const r = await reward.getDailyReward(day);
      expect(r).to.equal(0); // 1 * 0.9 = 0 (integer math)
    });

    it("reward never increases over time", async function () {
      const r1 = await reward.getDailyReward(1);
      const r2 = await reward.getDailyReward(1000);
      const r3 = await reward.getDailyReward(5000);

      expect(r2).to.be.lte(r1);
      expect(r3).to.be.lte(r2);
    });

    it("year above 30 uses year 30 value", async function () {
      const day31Year = 365 * 31;
      const day30Year = 365 * 30;

      const r31 = await reward.getDailyReward(day31Year);
      const r30 = await reward.getDailyReward(day30Year);

      expect(r31).to.equal(r30);
    });

    it("emits RewardQueried event", async function () {
      await expect(reward.getDailyReward(1))
        .to.emit(reward, "RewardQueried")
        .withArgs(1, 1, 1);
    });
  });

  /* -----------------------------------------------------------
   * getCurrentDailyReward
   * --------------------------------------------------------- */
  describe("getCurrentDailyReward", function () {
    it("returns correct current day and reward", async function () {
      await ethers.provider.send("evm_increaseTime", [DAY * 5]);
      await ethers.provider.send("evm_mine");

      const [dailyReward, currentDay] =
        await reward.getCurrentDailyReward();

      expect(currentDay).to.equal(6);
      expect(dailyReward).to.equal(1);
    });

    it("emits RewardQueried internally", async function () {
      await expect(reward.getCurrentDailyReward()).to.emit(
        reward,
        "RewardQueried"
      );
    });
  });

  /* -----------------------------------------------------------
   * getYearlyRewardInfo
   * --------------------------------------------------------- */
  describe("getYearlyRewardInfo", function () {
    it("reverts if year is zero", async function () {
      await expect(
        reward.getYearlyRewardInfo(0)
      ).to.be.revertedWith("Year must be positive");
    });

    it("returns correct reward and fixed=false for year <= 30", async function () {
      const [rewardValue, fixed] =
        await reward.getYearlyRewardInfo(1);

      expect(rewardValue).to.equal(1);
      expect(fixed).to.equal(false);
    });

    it("returns fixed=true for year > 30", async function () {
      const [, fixed] = await reward.getYearlyRewardInfo(31);
      expect(fixed).to.equal(true);
    });

    it("year > 30 returns same reward as year 30", async function () {
      const [r30] = await reward.getYearlyRewardInfo(30);
      const [r40] = await reward.getYearlyRewardInfo(40);

      expect(r40).to.equal(r30);
    });
  });

  /* -----------------------------------------------------------
   * getBatchDailyRewards
   * --------------------------------------------------------- */
  describe("getBatchDailyRewards", function () {
    it("reverts on invalid parameters", async function () {
      await expect(
        reward.getBatchDailyRewards(0, 1)
      ).to.be.revertedWith("Invalid parameters");

      await expect(
        reward.getBatchDailyRewards(1, 0)
      ).to.be.revertedWith("Invalid parameters");
    });

    it("returns correct rewards array", async function () {
      const rewards = await reward.getBatchDailyRewards(1, 5);

      expect(rewards.length).to.equal(5);
      for (let i = 0; i < rewards.length; i++) {
        expect(rewards[i]).to.equal(1);
      }
    });

    it("batch rewards follow decreasing rule", async function () {
      const rewards = await reward.getBatchDailyRewards(360, 10);

      for (let i = 1; i < rewards.length; i++) {
        expect(rewards[i]).to.be.lte(rewards[i - 1]);
      }
    });
  });

  /* -----------------------------------------------------------
   * Invariants / Safety
   * --------------------------------------------------------- */
  describe("Invariants", function () {
    it("reward is never negative", async function () {
      for (let i = 1; i <= 12000; i += 1000) {
        const r = await reward.getDailyReward(i);
        expect(r).to.be.gte(0);
      }
    });

    it("reward never exceeds initial reward", async function () {
      for (let i = 1; i <= 12000; i += 1000) {
        const r = await reward.getDailyReward(i);
        expect(r).to.be.lte(1);
      }
    });
  });
});
