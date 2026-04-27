const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture, time } = require("@nomicfoundation/hardhat-network-helpers");
const { anyValue } = require("@nomicfoundation/hardhat-chai-matchers/withArgs");

const USDT_DECIMALS = 6n;
const GBC_DECIMALS = 18n;
const STAKE_UNIT = 100n * 10n ** USDT_DECIMALS;
const ONE_STAKE = STAKE_UNIT;
const TWO_STAKE = STAKE_UNIT * 2n;

const HASHRATE = 10n ** 16n; // 0.01 GBC / hour when GBC decimals = 18
const BASIC_POWER = 3n * 10n ** 16n; // 0.03 GBC / hour when GBC decimals = 18
const HOUR = 60n * 60n;
const DAY = 24n * HOUR;

function rewardFor(power, secondsElapsed) {
  return (power * BigInt(secondsElapsed)) / HOUR;
}

function parseUsdt(value) {
  return ethers.parseUnits(value, Number(USDT_DECIMALS));
}

function parseGbc(value) {
  return ethers.parseUnits(value, Number(GBC_DECIMALS));
}

async function deployFixture() {
  const [deployer, owner, alice, bob, treasury, stranger, forwarder, rescueTo] =
    await ethers.getSigners();

  const MockERC1363Token = await ethers.getContractFactory("MockERC1363Token");

  const usdt = await MockERC1363Token.deploy("Mock USDT", "mUSDT", Number(USDT_DECIMALS));
  await usdt.waitForDeployment();

  const gbc = await MockERC1363Token.deploy("Mock GBC", "GBC", Number(GBC_DECIMALS));
  await gbc.waitForDeployment();

  const StakeMint = await ethers.getContractFactory("StakeMint");
  const stakeMint = await StakeMint.deploy(
    await usdt.getAddress(),
    await gbc.getAddress(),
    owner.address
  );
  await stakeMint.waitForDeployment();

  const stakeMintAddress = async () => await stakeMint.getAddress();

  await usdt.mint(alice.address, parseUsdt("10000"));
  await usdt.mint(bob.address, parseUsdt("10000"));
  await usdt.mint(treasury.address, parseUsdt("10000"));
  await gbc.mint(treasury.address, parseGbc("1000000000"));

  async function transferAndCall(user, amount) {
    return usdt.connect(user)["transferAndCall(address,uint256)"](
      await stakeMintAddress(),
      amount
    );
  }

  async function approveAndCall(user, amount) {
    return usdt.connect(user)["approveAndCall(address,uint256)"](
      await stakeMintAddress(),
      amount
    );
  }

  async function startAndStake(user, amount = ONE_STAKE) {
    await stakeMint.connect(user).startMint();
    await transferAndCall(user, amount);
  }

  async function fundRewards(amount = parseGbc("1000000")) {
    await gbc.connect(treasury).approve(await stakeMintAddress(), amount);
    return stakeMint.connect(treasury).fundRewards(amount);
  }

  return {
    deployer,
    owner,
    alice,
    bob,
    treasury,
    stranger,
    forwarder,
    rescueTo,
    usdt,
    gbc,
    stakeMint,
    stakeMintAddress,
    transferAndCall,
    approveAndCall,
    startAndStake,
    fundRewards,
  };
}

async function deployFeeStakeTokenFixture() {
  const [deployer, owner, alice, feeRecipient] = await ethers.getSigners();

  const MockFeeERC1363Token = await ethers.getContractFactory("MockFeeERC1363Token");
  const feeUsdt = await MockFeeERC1363Token.deploy(
    "Fee USDT",
    "fUSDT",
    Number(USDT_DECIMALS),
    100, // 1% fee
    feeRecipient.address
  );
  await feeUsdt.waitForDeployment();

  const MockERC1363Token = await ethers.getContractFactory("MockERC1363Token");
  const gbc = await MockERC1363Token.deploy("Mock GBC", "GBC", Number(GBC_DECIMALS));
  await gbc.waitForDeployment();

  const StakeMint = await ethers.getContractFactory("StakeMint");
  const stakeMint = await StakeMint.deploy(
    await feeUsdt.getAddress(),
    await gbc.getAddress(),
    owner.address
  );
  await stakeMint.waitForDeployment();

  await feeUsdt.mint(alice.address, parseUsdt("10000"));

  return { deployer, owner, alice, feeRecipient, feeUsdt, gbc, stakeMint };
}

async function deployFeeRewardTokenFixture() {
  const [deployer, owner, treasury, feeRecipient] = await ethers.getSigners();

  const MockERC1363Token = await ethers.getContractFactory("MockERC1363Token");
  const usdt = await MockERC1363Token.deploy("Mock USDT", "mUSDT", Number(USDT_DECIMALS));
  await usdt.waitForDeployment();

  const MockFeeERC1363Token = await ethers.getContractFactory("MockFeeERC1363Token");
  const feeGbc = await MockFeeERC1363Token.deploy(
    "Fee GBC",
    "fGBC",
    Number(GBC_DECIMALS),
    100, // 1% fee
    feeRecipient.address
  );
  await feeGbc.waitForDeployment();

  const StakeMint = await ethers.getContractFactory("StakeMint");
  const stakeMint = await StakeMint.deploy(
    await usdt.getAddress(),
    await feeGbc.getAddress(),
    owner.address
  );
  await stakeMint.waitForDeployment();

  await feeGbc.mint(treasury.address, parseGbc("1000000"));

  return { deployer, owner, treasury, feeRecipient, usdt, feeGbc, stakeMint };
}

describe("StakeMint.final.v1.0.0", function () {
  describe("deployment / config", function () {
    it("sets immutable config, version, owner, and initial snapshot", async function () {
      const { owner, usdt, gbc, stakeMint } = await loadFixture(deployFixture);

      expect(await stakeMint.CONTRACT_VERSION()).to.equal("1.0.0");
      expect(await stakeMint.owner()).to.equal(owner.address);
      expect(await stakeMint.USDT()).to.equal(await usdt.getAddress());
      expect(await stakeMint.GBC()).to.equal(await gbc.getAddress());

      expect(await stakeMint.GBC_DECIMALS()).to.equal(GBC_DECIMALS);
      expect(await stakeMint.STAKE_UNIT()).to.equal(STAKE_UNIT);
      expect(await stakeMint.HASHRATE()).to.equal(HASHRATE);
      expect(await stakeMint.BASICCOMPUTINGPOWER()).to.equal(BASIC_POWER);
      expect(await stakeMint.TIMEINTERVAL()).to.equal(DAY);
      expect(await stakeMint.UPDATE_INTERVAL()).to.equal(HOUR);
      expect(await stakeMint.MAX_HISTORY_LENGTH()).to.equal(168n);

      expect(await stakeMint.getHashPowerHistoryLength()).to.equal(1n);
      expect(await stakeMint.snapshotCounter()).to.equal(1n);

      const latest = await stakeMint.getLatestHashPowerSnapshot();
      expect(latest[1]).to.equal(0n); // totalHashPower
      expect(latest[2]).to.equal(0n); // totalStakedUsdt
      expect(latest[3]).to.equal(0n); // totalMiners

      const accounting = await stakeMint.getStakeTokenAccounting();
      expect(accounting[0]).to.equal(0n); // balance
      expect(accounting[1]).to.equal(0n); // accountedStake
      expect(accounting[2]).to.equal(0n); // surplus
      expect(accounting[3]).to.equal(0n); // shortfall
    });

    it("derives reward rates from GBC decimals", async function () {
      const [deployer, owner] = await ethers.getSigners();
      const MockERC1363Token = await ethers.getContractFactory("MockERC1363Token");
      const usdt = await MockERC1363Token.deploy("Mock USDT", "mUSDT", 6);
      const gbc6 = await MockERC1363Token.deploy("Mock GBC6", "GBC6", 6);
      await usdt.waitForDeployment();
      await gbc6.waitForDeployment();

      const StakeMint = await ethers.getContractFactory("StakeMint");
      const stakeMint = await StakeMint.deploy(
        await usdt.getAddress(),
        await gbc6.getAddress(),
        owner.address
      );
      await stakeMint.waitForDeployment();

      expect(await stakeMint.GBC_DECIMALS()).to.equal(6n);
      expect(await stakeMint.HASHRATE()).to.equal(10_000n); // 0.01 GBC6
      expect(await stakeMint.BASICCOMPUTINGPOWER()).to.equal(30_000n); // 0.03 GBC6
    });

    it("rejects invalid constructor parameters", async function () {
      const { owner, usdt, gbc, alice } = await loadFixture(deployFixture);
      const StakeMint = await ethers.getContractFactory("StakeMint");
      const MockERC1363Token = await ethers.getContractFactory("MockERC1363Token");

      const usdtBadDecimals = await MockERC1363Token.deploy("Bad USDT", "BADU", 37);
      const gbcBadDecimals = await MockERC1363Token.deploy("Bad GBC", "BADG", 1);
      await usdtBadDecimals.waitForDeployment();
      await gbcBadDecimals.waitForDeployment();

      await expect(
        StakeMint.deploy(ethers.ZeroAddress, await gbc.getAddress(), owner.address)
      )
        .to.be.revertedWithCustomError(StakeMint, "InvalidTokenAddress")
        .withArgs(ethers.ZeroAddress);

      await expect(
        StakeMint.deploy(alice.address, await gbc.getAddress(), owner.address)
      )
        .to.be.revertedWithCustomError(StakeMint, "InvalidTokenAddress")
        .withArgs(alice.address);

      await expect(
        StakeMint.deploy(await usdt.getAddress(), ethers.ZeroAddress, owner.address)
      )
        .to.be.revertedWithCustomError(StakeMint, "InvalidTokenAddress")
        .withArgs(ethers.ZeroAddress);

      await expect(
        StakeMint.deploy(await usdtBadDecimals.getAddress(), await gbc.getAddress(), owner.address)
      )
        .to.be.revertedWithCustomError(StakeMint, "InvalidTokenDecimals")
        .withArgs(37);

      await expect(
        StakeMint.deploy(await usdt.getAddress(), await gbcBadDecimals.getAddress(), owner.address)
      )
        .to.be.revertedWithCustomError(StakeMint, "InvalidTokenDecimals")
        .withArgs(1);

      await expect(
        StakeMint.deploy(await usdt.getAddress(), await gbc.getAddress(), ethers.ZeroAddress)
      )
        .to.be.revertedWithCustomError(StakeMint, "OwnableInvalidOwner")
        .withArgs(ethers.ZeroAddress);
    });

    it("supports ERC165 + ERC1363 receiver/spender interfaces", async function () {
      const { stakeMint } = await loadFixture(deployFixture);

      const erc165InterfaceId = "0x01ffc9a7";
      const receiverInterfaceId = ethers.id(
        "onTransferReceived(address,address,uint256,bytes)"
      ).slice(0, 10);
      const spenderInterfaceId = ethers.id(
        "onApprovalReceived(address,uint256,bytes)"
      ).slice(0, 10);

      expect(await stakeMint.supportsInterface(erc165InterfaceId)).to.equal(true);
      expect(await stakeMint.supportsInterface(receiverInterfaceId)).to.equal(true);
      expect(await stakeMint.supportsInterface(spenderInterfaceId)).to.equal(true);
      expect(await stakeMint.supportsInterface("0xffffffff")).to.equal(false);
    });
  });

  describe("startMint", function () {
    it("starts mining and registers user without making them active before staking", async function () {
      const { alice, stakeMint } = await loadFixture(deployFixture);

      await expect(stakeMint.connect(alice).startMint())
        .to.emit(stakeMint, "StartMint")
        .withArgs(alice.address, true, anyValue, anyValue);

      const m = await stakeMint.minter(alice.address);
      expect(m[0]).to.equal(true); // isStartMint
      expect(m[1]).to.be.greaterThan(0n); // startMintTime
      expect(m[2]).to.equal(m[1]); // lastMintTime
      expect(m[3]).to.equal(m[1]); // lastClaimTime
      expect(m[4]).to.equal(0n); // rewardRemainder
      expect(m[5]).to.equal(0n); // totalUsdt
      expect(m[6]).to.equal(0n); // accruedRewards

      expect(await stakeMint.getTotalMiners()).to.equal(1n);
      expect(await stakeMint.getActiveMiners()).to.equal(0n);
      expect(await stakeMint.getPower(alice.address)).to.equal(0n);
      expect(await stakeMint.getCurrentTotalHashPower()).to.equal(0n);
    });

    it("rejects duplicate startMint", async function () {
      const { alice, stakeMint } = await loadFixture(deployFixture);

      await stakeMint.connect(alice).startMint();

      await expect(stakeMint.connect(alice).startMint())
        .to.be.revertedWithCustomError(stakeMint, "MiningAlreadyStarted")
        .withArgs(alice.address);
    });
  });

  describe("ERC1363 staking", function () {
    it("rejects transferAndCall / approveAndCall before startMint", async function () {
      const { alice, stakeMint, transferAndCall, approveAndCall } = await loadFixture(deployFixture);

      await expect(transferAndCall(alice, ONE_STAKE))
        .to.be.revertedWithCustomError(stakeMint, "MiningNotStarted")
        .withArgs(alice.address);

      await expect(approveAndCall(alice, ONE_STAKE))
        .to.be.revertedWithCustomError(stakeMint, "MiningNotStarted")
        .withArgs(alice.address);
    });

    it("rejects non-unit stake amounts", async function () {
      const { alice, stakeMint, transferAndCall } = await loadFixture(deployFixture);

      await stakeMint.connect(alice).startMint();

      await expect(transferAndCall(alice, ONE_STAKE + 1n))
        .to.be.revertedWithCustomError(stakeMint, "InvalidStakeAmount")
        .withArgs(ONE_STAKE + 1n);
    });

    it("stakes through transferAndCall and updates user/global accounting", async function () {
      const { alice, usdt, stakeMint, stakeMintAddress, transferAndCall } =
        await loadFixture(deployFixture);

      await stakeMint.connect(alice).startMint();

      await expect(transferAndCall(alice, ONE_STAKE))
        .to.emit(stakeMint, "StakedViaTransferAndCall")
        .withArgs(alice.address, alice.address, ONE_STAKE);

      const m = await stakeMint.minter(alice.address);
      expect(m[5]).to.equal(ONE_STAKE);
      expect(await stakeMint.totalStakedUsdt()).to.equal(ONE_STAKE);
      expect(await stakeMint.getActiveMiners()).to.equal(1n);
      expect(await stakeMint.getPower(alice.address)).to.equal(BASIC_POWER + HASHRATE);
      expect(await stakeMint.getCurrentTotalHashPower()).to.equal(BASIC_POWER + HASHRATE);
      expect(await usdt.balanceOf(await stakeMintAddress())).to.equal(ONE_STAKE);
    });

    it("stakes through approveAndCall and consumes allowance", async function () {
      const { alice, usdt, stakeMint, stakeMintAddress, approveAndCall } =
        await loadFixture(deployFixture);

      await stakeMint.connect(alice).startMint();

      await expect(approveAndCall(alice, TWO_STAKE))
        .to.emit(stakeMint, "StakedViaApproveAndCall")
        .withArgs(alice.address, TWO_STAKE);

      const m = await stakeMint.minter(alice.address);
      expect(m[5]).to.equal(TWO_STAKE);
      expect(await stakeMint.totalStakedUsdt()).to.equal(TWO_STAKE);
      expect(await usdt.allowance(alice.address, await stakeMintAddress())).to.equal(0n);
      expect(await stakeMint.getPower(alice.address)).to.equal(BASIC_POWER + 2n * HASHRATE);
    });

    it("rejects direct callbacks from non-USDT callers", async function () {
      const { alice, stakeMint } = await loadFixture(deployFixture);

      await expect(
        stakeMint.connect(alice).onTransferReceived(alice.address, alice.address, ONE_STAKE, "0x")
      )
        .to.be.revertedWithCustomError(stakeMint, "OnlyUSDTAllowed")
        .withArgs(alice.address);

      await expect(
        stakeMint.connect(alice).onApprovalReceived(alice.address, ONE_STAKE, "0x")
      )
        .to.be.revertedWithCustomError(stakeMint, "OnlyUSDTAllowed")
        .withArgs(alice.address);
    });

    it("allows transferAndCall even when surplus USDT exists, and reports/rescues surplus", async function () {
      const { owner, alice, bob, usdt, stakeMint, stakeMintAddress, transferAndCall, rescueTo } =
        await loadFixture(deployFixture);

      await stakeMint.connect(alice).startMint();
      await transferAndCall(alice, ONE_STAKE);

      await usdt.connect(bob).transfer(await stakeMintAddress(), ONE_STAKE);

      let accounting = await stakeMint.getStakeTokenAccounting();
      expect(accounting[0]).to.equal(TWO_STAKE); // balance
      expect(accounting[1]).to.equal(ONE_STAKE); // accountedStake
      expect(accounting[2]).to.equal(ONE_STAKE); // surplus
      expect(accounting[3]).to.equal(0n); // shortfall

      await expect(transferAndCall(alice, ONE_STAKE))
        .to.emit(stakeMint, "StakedViaTransferAndCall")
        .withArgs(alice.address, alice.address, ONE_STAKE);

      accounting = await stakeMint.getStakeTokenAccounting();
      expect(accounting[0]).to.equal(3n * ONE_STAKE);
      expect(accounting[1]).to.equal(TWO_STAKE);
      expect(accounting[2]).to.equal(ONE_STAKE);
      expect(accounting[3]).to.equal(0n);

      await expect(stakeMint.connect(owner).rescueStakeTokenSurplus(rescueTo.address, ONE_STAKE))
        .to.emit(stakeMint, "TokenRescued")
        .withArgs(await usdt.getAddress(), rescueTo.address, ONE_STAKE);

      accounting = await stakeMint.getStakeTokenAccounting();
      expect(accounting[0]).to.equal(TWO_STAKE);
      expect(accounting[1]).to.equal(TWO_STAKE);
      expect(accounting[2]).to.equal(0n);
      expect(accounting[3]).to.equal(0n);
    });

    it("reports shortfall when the principal pool becomes undercollateralized", async function () {
      const { alice, usdt, stakeMint, stakeMintAddress, startAndStake } = await loadFixture(deployFixture);

      await startAndStake(alice, ONE_STAKE);
      await usdt.burn(await stakeMintAddress(), 1n);

      const accounting = await stakeMint.getStakeTokenAccounting();
      expect(accounting[0]).to.equal(ONE_STAKE - 1n);
      expect(accounting[1]).to.equal(ONE_STAKE);
      expect(accounting[2]).to.equal(0n);
      expect(accounting[3]).to.equal(1n);
    });
  });

  describe("fee-on-transfer handling", function () {
    it("rejects fee-on-transfer stake token through approveAndCall", async function () {
      const { alice, feeUsdt, stakeMint } = await loadFixture(deployFeeStakeTokenFixture);
      const stakeMintAddress = await stakeMint.getAddress();
      const received = ONE_STAKE - ONE_STAKE / 100n;

      await stakeMint.connect(alice).startMint();

      await expect(
        feeUsdt.connect(alice)["approveAndCall(address,uint256)"](stakeMintAddress, ONE_STAKE)
      )
        .to.be.revertedWithCustomError(stakeMint, "TransferAmountMismatch")
        .withArgs(ONE_STAKE, received);
    });

    it("rejects fee-on-transfer stake token through transferAndCall when no surplus covers the fee", async function () {
      const { alice, feeUsdt, stakeMint } = await loadFixture(deployFeeStakeTokenFixture);
      const stakeMintAddress = await stakeMint.getAddress();
      const received = ONE_STAKE - ONE_STAKE / 100n;

      await stakeMint.connect(alice).startMint();

      await expect(
        feeUsdt.connect(alice)["transferAndCall(address,uint256)"](stakeMintAddress, ONE_STAKE)
      )
        .to.be.revertedWithCustomError(stakeMint, "InsufficientUSDT")
        .withArgs(ONE_STAKE, received);
    });

    it("rejects fee-on-transfer GBC reward funding", async function () {
      const { treasury, feeGbc, stakeMint } = await loadFixture(deployFeeRewardTokenFixture);
      const stakeMintAddress = await stakeMint.getAddress();
      const amount = parseGbc("1000");
      const received = amount - amount / 100n;

      await feeGbc.connect(treasury).approve(stakeMintAddress, amount);

      await expect(stakeMint.connect(treasury).fundRewards(amount))
        .to.be.revertedWithCustomError(stakeMint, "TransferAmountMismatch")
        .withArgs(amount, received);
    });
  });

  describe("rewards", function () {
    it("calculates pending rewards and blocks claims before TIMEINTERVAL", async function () {
      const { alice, stakeMint, startAndStake } = await loadFixture(deployFixture);

      await startAndStake(alice, ONE_STAKE);

      const m0 = await stakeMint.minter(alice.address);
      const power = await stakeMint.getPower(alice.address);
      const expectedAfterHour = rewardFor(power, HOUR);

      await time.increaseTo(Number(m0[2] + HOUR));

      const pending = await stakeMint.pendingRewards(alice.address);
      expect(pending[0]).to.equal(expectedAfterHour);
      expect(pending[1]).to.equal(power);

      const claimable = await stakeMint.claimableRewards(alice.address);
      expect(claimable[0]).to.equal(expectedAfterHour);
      expect(claimable[2]).to.equal(false);
      expect(claimable[3]).to.equal(m0[3] + DAY);

      await expect(stakeMint.connect(alice).withdrawRewards())
        .to.be.revertedWithCustomError(stakeMint, "ClaimTooSoon")
        .withArgs(m0[3] + DAY);
    });

    it("claims rewards after 24 hours when the pool is funded", async function () {
      const { alice, gbc, stakeMint, startAndStake, fundRewards } = await loadFixture(deployFixture);

      await startAndStake(alice, ONE_STAKE);
      await fundRewards();

      const m0 = await stakeMint.minter(alice.address);
      const power = await stakeMint.getPower(alice.address);
      const targetTimestamp = m0[2] + DAY;
      const expectedReward = rewardFor(power, DAY);

      await time.setNextBlockTimestamp(Number(targetTimestamp));

      await expect(stakeMint.connect(alice).withdrawRewards())
        .to.emit(stakeMint, "WithdrawRewards")
        .withArgs(alice.address, expectedReward);

      expect(await gbc.balanceOf(alice.address)).to.equal(expectedReward);

      const m1 = await stakeMint.minter(alice.address);
      expect(m1[2]).to.equal(targetTimestamp); // lastMintTime
      expect(m1[3]).to.equal(targetTimestamp); // lastClaimTime
      expect(m1[4]).to.equal(0n); // rewardRemainder
      expect(m1[6]).to.equal(0n); // accruedRewards
    });

    it("accrues old rewards before adding new stake, preventing retroactive inflation", async function () {
      const { alice, stakeMint, transferAndCall } = await loadFixture(deployFixture);

      await stakeMint.connect(alice).startMint();
      await transferAndCall(alice, ONE_STAKE);

      const afterFirstStake = await stakeMint.minter(alice.address);
      const firstPower = BASIC_POWER + HASHRATE;
      const secondPower = BASIC_POWER + 2n * HASHRATE;

      await time.setNextBlockTimestamp(Number(afterFirstStake[2] + DAY));
      await transferAndCall(alice, ONE_STAKE);

      const afterSecondStake = await stakeMint.minter(alice.address);
      expect(afterSecondStake[5]).to.equal(TWO_STAKE);
      expect(afterSecondStake[6]).to.equal(rewardFor(firstPower, DAY));
      expect(await stakeMint.getPower(alice.address)).to.equal(secondPower);
      expect(await stakeMint.getCurrentTotalHashPower()).to.equal(secondPower);

      await time.increaseTo(Number(afterSecondStake[2] + HOUR));
      const pending = await stakeMint.pendingRewards(alice.address);

      expect(pending[0]).to.equal(rewardFor(firstPower, DAY) + rewardFor(secondPower, HOUR));
      expect(pending[1]).to.equal(secondPower);
    });

    it("keeps accrued rewards after full principal withdrawal and clears only remainder", async function () {
      const { alice, gbc, stakeMint, startAndStake, fundRewards } = await loadFixture(deployFixture);

      await startAndStake(alice, ONE_STAKE);

      const m0 = await stakeMint.minter(alice.address);
      const power = await stakeMint.getPower(alice.address);
      const expectedReward = rewardFor(power, 1n);

      await time.setNextBlockTimestamp(Number(m0[2] + 1n));
      await stakeMint.connect(alice).withdrawStakeUsdt(ONE_STAKE);

      const m1 = await stakeMint.minter(alice.address);
      expect(m1[5]).to.equal(0n); // totalUsdt
      expect(m1[6]).to.equal(expectedReward); // accruedRewards
      expect(m1[4]).to.equal(0n); // rewardRemainder was cleared on full withdrawal
      expect(await stakeMint.getPower(alice.address)).to.equal(0n);

      const pending = await stakeMint.pendingRewards(alice.address);
      expect(pending[0]).to.equal(expectedReward);
      expect(pending[1]).to.equal(0n);

      // 还没过 24 小时，不能领取，但已记账奖励不会丢。
      await expect(stakeMint.connect(alice).withdrawRewards())
        .to.be.revertedWithCustomError(stakeMint, "ClaimTooSoon");

      await time.increaseTo(Number(m0[3] + DAY));
      await fundRewards();
      await expect(stakeMint.connect(alice).withdrawRewards())
        .to.emit(stakeMint, "WithdrawRewards")
        .withArgs(alice.address, expectedReward);

      expect(await gbc.balanceOf(alice.address)).to.equal(expectedReward);
    });

    it("does not block principal withdrawal when the GBC pool is insufficient", async function () {
      const { alice, usdt, stakeMint, startAndStake } = await loadFixture(deployFixture);

      const initialUsdt = await usdt.balanceOf(alice.address);

      await startAndStake(alice, ONE_STAKE);

      const m0 = await stakeMint.minter(alice.address);
      const power = await stakeMint.getPower(alice.address);
      const expectedReward = rewardFor(power, DAY);

      await time.setNextBlockTimestamp(Number(m0[2] + DAY));

      await expect(stakeMint.connect(alice).withdrawRewards())
        .to.be.revertedWithCustomError(stakeMint, "InsufficientGBC")
        .withArgs(expectedReward, 0n);

      await expect(stakeMint.connect(alice).withdrawStakeUsdt(ONE_STAKE))
        .to.emit(stakeMint, "WithdrawStake")
        .withArgs(alice.address, ONE_STAKE);

      expect(await usdt.balanceOf(alice.address)).to.equal(initialUsdt);
      expect(await stakeMint.totalStakedUsdt()).to.equal(0n);
      expect(await stakeMint.getActiveMiners()).to.equal(0n);
      expect(await stakeMint.getCurrentTotalHashPower()).to.equal(0n);
    });
  });

  describe("withdrawStakeUsdt", function () {
    it("rejects invalid withdrawal amounts", async function () {
      const { alice, stakeMint, startAndStake } = await loadFixture(deployFixture);

      await startAndStake(alice, TWO_STAKE);

      await expect(stakeMint.connect(alice).withdrawStakeUsdt(0n))
        .to.be.revertedWithCustomError(stakeMint, "InvalidWithdrawAmount")
        .withArgs(0n);

      await expect(stakeMint.connect(alice).withdrawStakeUsdt(TWO_STAKE + 1n))
        .to.be.revertedWithCustomError(stakeMint, "InvalidWithdrawAmount")
        .withArgs(TWO_STAKE + 1n);

      await expect(stakeMint.connect(alice).withdrawStakeUsdt(1n))
        .to.be.revertedWithCustomError(stakeMint, "InvalidWithdrawAmount")
        .withArgs(1n);
    });

    it("withdraws partially and fully while updating active miners and hash power", async function () {
      const { alice, usdt, stakeMint, stakeMintAddress, startAndStake } = await loadFixture(deployFixture);

      await startAndStake(alice, TWO_STAKE);

      expect(await stakeMint.totalStakedUsdt()).to.equal(TWO_STAKE);
      expect(await stakeMint.getActiveMiners()).to.equal(1n);
      expect(await stakeMint.getCurrentTotalHashPower()).to.equal(BASIC_POWER + 2n * HASHRATE);

      await expect(stakeMint.connect(alice).withdrawStakeUsdt(ONE_STAKE))
        .to.emit(stakeMint, "WithdrawStake")
        .withArgs(alice.address, ONE_STAKE);

      expect(await stakeMint.totalStakedUsdt()).to.equal(ONE_STAKE);
      expect(await stakeMint.getActiveMiners()).to.equal(1n);
      expect(await stakeMint.getCurrentTotalHashPower()).to.equal(BASIC_POWER + HASHRATE);
      expect(await usdt.balanceOf(await stakeMintAddress())).to.equal(ONE_STAKE);

      await expect(stakeMint.connect(alice).withdrawStakeUsdt(ONE_STAKE))
        .to.emit(stakeMint, "WithdrawStake")
        .withArgs(alice.address, ONE_STAKE);

      expect(await stakeMint.totalStakedUsdt()).to.equal(0n);
      expect(await stakeMint.getActiveMiners()).to.equal(0n);
      expect(await stakeMint.getCurrentTotalHashPower()).to.equal(0n);
      expect(await stakeMint.getPower(alice.address)).to.equal(0n);
      expect(await usdt.balanceOf(await stakeMintAddress())).to.equal(0n);
    });
  });

  describe("getMinter aggregate view", function () {
    it("returns packed miner state plus derived power/reward/claimability", async function () {
      const { alice, stakeMint, startAndStake } = await loadFixture(deployFixture);

      await startAndStake(alice, ONE_STAKE);
      const m = await stakeMint.minter(alice.address);
      const power = await stakeMint.getPower(alice.address);

      await time.increaseTo(Number(m[2] + HOUR));

      const view = await stakeMint.getMinter(alice.address);
      expect(view[0]).to.equal(true); // isStartMint
      expect(view[1]).to.equal(m[1]); // startMintTime
      expect(view[2]).to.equal(m[2]); // lastMintTime
      expect(view[3]).to.equal(m[3]); // lastClaimTime
      expect(view[4]).to.equal(ONE_STAKE); // totalUsdt
      expect(view[5]).to.equal(0n); // accruedRewards
      expect(view[6]).to.equal(0n); // rewardRemainder in storage before write action
      expect(view[7]).to.equal(power); // power
      expect(view[8]).to.equal(rewardFor(power, HOUR)); // pendingReward
      expect(view[9]).to.equal(false); // claimable
      expect(view[10]).to.equal(m[3] + DAY); // nextClaimTime
    });
  });

  describe("Chainlink Automation and snapshots", function () {
    it("reports upkeep status and performs snapshot only after interval", async function () {
      const { stakeMint } = await loadFixture(deployFixture);

      let check = await stakeMint.checkUpkeep("0x1234");
      expect(check[0]).to.equal(false);
      expect(check[1]).to.equal("0x");

      await expect(stakeMint.performUpkeep("0x1234"))
        .to.be.revertedWithCustomError(stakeMint, "UpkeepNotNeeded");

      const lastUpdate = await stakeMint.lastUpdateTime();
      await time.increaseTo(Number(lastUpdate + HOUR));

      check = await stakeMint.checkUpkeep("0x");
      expect(check[0]).to.equal(true);

      await expect(stakeMint.performUpkeep("0x"))
        .to.emit(stakeMint, "HashPowerUpdated")
        .withArgs(anyValue, anyValue, 0n, 0n, 0n);

      expect(await stakeMint.getHashPowerHistoryLength()).to.equal(2n);
      expect(await stakeMint.snapshotCounter()).to.equal(2n);
    });

    it("enforces optional automation forwarder", async function () {
      const { owner, stranger, forwarder, stakeMint } = await loadFixture(deployFixture);

      await expect(stakeMint.connect(stranger).setAutomationForwarder(forwarder.address))
        .to.be.revertedWithCustomError(stakeMint, "OwnableUnauthorizedAccount")
        .withArgs(stranger.address);

      await expect(stakeMint.connect(owner).setAutomationForwarder(forwarder.address))
        .to.emit(stakeMint, "AutomationForwarderUpdated")
        .withArgs(ethers.ZeroAddress, forwarder.address);

      let lastUpdate = await stakeMint.lastUpdateTime();
      await time.increaseTo(Number(lastUpdate + HOUR));

      await expect(stakeMint.connect(stranger).performUpkeep("0x"))
        .to.be.revertedWithCustomError(stakeMint, "UnauthorizedUpkeepCaller")
        .withArgs(stranger.address);

      await expect(stakeMint.connect(forwarder).performUpkeep("0x"))
        .to.emit(stakeMint, "HashPowerUpdated");

      lastUpdate = await stakeMint.lastUpdateTime();
      await time.increaseTo(Number(lastUpdate + HOUR));

      await expect(stakeMint.connect(owner).performUpkeep("0x"))
        .to.emit(stakeMint, "HashPowerUpdated");
    });

    it("manualUpdateHashPower resets automation cadence, while manualCreateHashPowerSnapshot does not", async function () {
      const { owner, stakeMint } = await loadFixture(deployFixture);

      const originalLastUpdate = await stakeMint.lastUpdateTime();

      await time.increase(123);
      await expect(stakeMint.connect(owner).manualCreateHashPowerSnapshot())
        .to.emit(stakeMint, "HashPowerUpdated");

      expect(await stakeMint.lastUpdateTime()).to.equal(originalLastUpdate);

      await time.increase(456);
      const tx = await stakeMint.connect(owner).manualUpdateHashPower();
      const receipt = await tx.wait();
      const block = await ethers.provider.getBlock(receipt.blockNumber);

      expect(await stakeMint.lastUpdateTime()).to.equal(BigInt(block.timestamp));
    });

    it("stores only latest MAX_HISTORY_LENGTH snapshots and validates indexes", async function () {
      const { owner, stakeMint } = await loadFixture(deployFixture);

      const maxLength = await stakeMint.MAX_HISTORY_LENGTH();
      const loops = Number(maxLength) + 5;

      for (let i = 0; i < loops; i++) {
        await stakeMint.connect(owner).manualCreateHashPowerSnapshot();
      }

      expect(await stakeMint.getHashPowerHistoryLength()).to.equal(maxLength);
      expect(await stakeMint.snapshotCounter()).to.equal(1n + BigInt(loops));

      await expect(stakeMint.getHashPowerSnapshot(maxLength))
        .to.be.revertedWithCustomError(stakeMint, "IndexOutOfBounds")
        .withArgs(maxLength, maxLength);

      const recent = await stakeMint.getRecentHashPowerSnapshots(3n);
      expect(recent.length).to.equal(3);

      const overRequested = await stakeMint.getRecentHashPowerSnapshots(maxLength + 999n);
      expect(overRequested.length).to.equal(Number(maxLength));

      await expect(stakeMint.getRecentHashPowerSnapshots(0n))
        .to.be.revertedWithCustomError(stakeMint, "CountMustBePositive");
    });
  });

  describe("pause", function () {
    it("only owner can pause and unpause", async function () {
      const { owner, alice, stakeMint } = await loadFixture(deployFixture);

      await expect(stakeMint.connect(alice).pause())
        .to.be.revertedWithCustomError(stakeMint, "OwnableUnauthorizedAccount")
        .withArgs(alice.address);

      await stakeMint.connect(owner).pause();
      expect(await stakeMint.paused()).to.equal(true);

      await expect(stakeMint.connect(alice).unpause())
        .to.be.revertedWithCustomError(stakeMint, "OwnableUnauthorizedAccount")
        .withArgs(alice.address);

      await stakeMint.connect(owner).unpause();
      expect(await stakeMint.paused()).to.equal(false);
    });

    it("blocks startMint, staking and rewards while paused, but allows principal withdrawal", async function () {
      const { owner, alice, stakeMint, transferAndCall, startAndStake, fundRewards } =
        await loadFixture(deployFixture);

      await stakeMint.connect(owner).pause();

      await expect(stakeMint.connect(alice).startMint())
        .to.be.revertedWithCustomError(stakeMint, "EnforcedPause");

      await stakeMint.connect(owner).unpause();
      await startAndStake(alice, ONE_STAKE);
      await fundRewards();

      const m0 = await stakeMint.minter(alice.address);
      await time.increaseTo(Number(m0[2] + DAY));

      await stakeMint.connect(owner).pause();

      await expect(transferAndCall(alice, ONE_STAKE))
        .to.be.revertedWithCustomError(stakeMint, "EnforcedPause");

      await expect(stakeMint.connect(alice).withdrawRewards())
        .to.be.revertedWithCustomError(stakeMint, "EnforcedPause");

      await expect(stakeMint.connect(alice).withdrawStakeUsdt(ONE_STAKE))
        .to.emit(stakeMint, "WithdrawStake")
        .withArgs(alice.address, ONE_STAKE);
    });
  });

  describe("owner rescue functions", function () {
    it("rescues non-protected tokens and rejects protected token rescue", async function () {
      const { owner, alice, usdt, gbc, stakeMint, stakeMintAddress, rescueTo } = await loadFixture(deployFixture);
      const MockERC1363Token = await ethers.getContractFactory("MockERC1363Token");
      const other = await MockERC1363Token.deploy("Other", "OTH", 18);
      await other.waitForDeployment();

      const amount = parseGbc("100");
      await other.mint(await stakeMintAddress(), amount);

      await expect(stakeMint.connect(alice).rescueToken(await other.getAddress(), rescueTo.address, amount))
        .to.be.revertedWithCustomError(stakeMint, "OwnableUnauthorizedAccount")
        .withArgs(alice.address);

      await expect(stakeMint.connect(owner).rescueToken(await usdt.getAddress(), rescueTo.address, 1n))
        .to.be.revertedWithCustomError(stakeMint, "ProtectedToken")
        .withArgs(await usdt.getAddress());

      await expect(stakeMint.connect(owner).rescueToken(await gbc.getAddress(), rescueTo.address, 1n))
        .to.be.revertedWithCustomError(stakeMint, "ProtectedToken")
        .withArgs(await gbc.getAddress());

      await expect(stakeMint.connect(owner).rescueToken(await other.getAddress(), rescueTo.address, amount))
        .to.emit(stakeMint, "TokenRescued")
        .withArgs(await other.getAddress(), rescueTo.address, amount);

      expect(await other.balanceOf(rescueTo.address)).to.equal(amount);
    });

    it("rescues only surplus USDT and never accounted principal", async function () {
      const { owner, alice, bob, usdt, stakeMint, stakeMintAddress, startAndStake, rescueTo } =
        await loadFixture(deployFixture);

      await startAndStake(alice, ONE_STAKE);

      await expect(stakeMint.connect(owner).rescueStakeTokenSurplus(rescueTo.address, 1n))
        .to.be.revertedWithCustomError(stakeMint, "RescueAmountTooLarge")
        .withArgs(1n, 0n);

      await usdt.connect(bob).transfer(await stakeMintAddress(), ONE_STAKE);

      await expect(stakeMint.connect(owner).rescueStakeTokenSurplus(rescueTo.address, ONE_STAKE + 1n))
        .to.be.revertedWithCustomError(stakeMint, "RescueAmountTooLarge")
        .withArgs(ONE_STAKE + 1n, ONE_STAKE);

      await expect(stakeMint.connect(owner).rescueStakeTokenSurplus(rescueTo.address, ONE_STAKE))
        .to.emit(stakeMint, "TokenRescued")
        .withArgs(await usdt.getAddress(), rescueTo.address, ONE_STAKE);

      expect(await usdt.balanceOf(rescueTo.address)).to.equal(ONE_STAKE);
      expect(await stakeMint.totalStakedUsdt()).to.equal(ONE_STAKE);
      expect(await usdt.balanceOf(await stakeMintAddress())).to.equal(ONE_STAKE);
    });
  });
});
