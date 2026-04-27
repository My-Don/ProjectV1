const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture, time } = require("@nomicfoundation/hardhat-network-helpers");

describe("AdvancedERC314DividendToken", function () {
  const ZERO = ethers.ZeroAddress;

  const SUPPLY = ethers.parseEther("1000000");
  const ERC314_TOKEN_LIQUIDITY = ethers.parseEther("100000");
  const ERC314_NATIVE_LIQUIDITY = ethers.parseEther("10");

  async function deployFixture() {
    const [owner, feeReceiver, alice, bob, treasury, attacker] = await ethers.getSigners();

    const MockERC20 = await ethers.getContractFactory("MockERC20");

    const rewardToken = await MockERC20.deploy(
      "Mock USDT",
      "mUSDT",
      owner.address,
      ethers.parseEther("1000000000")
    );

    await rewardToken.waitForDeployment();

    const Token = await ethers.getContractFactory("AdvancedERC314DividendToken");

    const token = await Token.deploy(
      "BKC Token",
      "BKC",
      SUPPLY,
      owner.address,
      feeReceiver.address,
      ZERO,
      await rewardToken.getAddress()
    );

    await token.waitForDeployment();

    return {
      owner,
      feeReceiver,
      alice,
      bob,
      treasury,
      attacker,
      rewardToken,
      token,
    };
  }

  async function deployWithRouterFixture() {
    const [owner, feeReceiver, alice, bob, treasury] = await ethers.getSigners();

    const MockERC20 = await ethers.getContractFactory("MockERC20");

    const rewardToken = await MockERC20.deploy(
      "Mock USDT",
      "mUSDT",
      owner.address,
      ethers.parseEther("1000000000")
    );

    await rewardToken.waitForDeployment();

    const weth = await MockERC20.deploy("Wrapped ETH", "WETH", owner.address, 0);
    await weth.waitForDeployment();

    const MockFactory = await ethers.getContractFactory("MockFactory");
    const factory1 = await MockFactory.deploy();
    await factory1.waitForDeployment();

    const factory2 = await MockFactory.deploy();
    await factory2.waitForDeployment();

    const MockRouter = await ethers.getContractFactory("MockRouter");

    const router1 = await MockRouter.deploy(await weth.getAddress(), await factory1.getAddress());
    await router1.waitForDeployment();

    const router2 = await MockRouter.deploy(await weth.getAddress(), await factory2.getAddress());
    await router2.waitForDeployment();

    const Token = await ethers.getContractFactory("AdvancedERC314DividendToken");

    const token = await Token.deploy(
      "BKC Token",
      "BKC",
      SUPPLY,
      owner.address,
      feeReceiver.address,
      await router1.getAddress(),
      await rewardToken.getAddress()
    );

    await token.waitForDeployment();

    return {
      owner,
      feeReceiver,
      alice,
      bob,
      treasury,
      rewardToken,
      weth,
      factory1,
      factory2,
      router1,
      router2,
      token,
    };
  }

  async function addErc314LiquidityFixture() {
    const base = await deployFixture();
    const { owner, token } = base;

    const tokenAddress = await token.getAddress();

    // 管理员先授权合约从自己钱包扣代币
    await token.approve(tokenAddress, ERC314_TOKEN_LIQUIDITY);

    // 添加 ERC314 内置池子的代币和 ETH/BNB 流动性
    await token.addErc314Liquidity(ERC314_TOKEN_LIQUIDITY, {
      value: ERC314_NATIVE_LIQUIDITY,
    });

    return base;
  }

  describe("部署初始化", function () {
    it("应正确初始化基础参数和权限", async function () {
      const { owner, feeReceiver, token } = await loadFixture(deployFixture);

      expect(await token.name()).to.equal("BKC Token");
      expect(await token.symbol()).to.equal("BKC");
      expect(await token.totalSupply()).to.equal(SUPPLY);
      expect(await token.balanceOf(owner.address)).to.equal(SUPPLY);

      expect(await token.feeReceiver()).to.equal(feeReceiver.address);

      expect(await token.publicErc314SwapEnabled()).to.equal(false);
      expect(await token.publicAmmSwapEnabled()).to.equal(false);
      expect(await token.erc314SellByTransferEnabled()).to.equal(false);

      const DEFAULT_ADMIN_ROLE = await token.DEFAULT_ADMIN_ROLE();
      const TAX_MANAGER_ROLE = await token.TAX_MANAGER_ROLE();
      const LIQUIDITY_MANAGER_ROLE = await token.LIQUIDITY_MANAGER_ROLE();

      expect(await token.hasRole(DEFAULT_ADMIN_ROLE, owner.address)).to.equal(true);
      expect(await token.hasRole(TAX_MANAGER_ROLE, owner.address)).to.equal(true);
      expect(await token.hasRole(LIQUIDITY_MANAGER_ROLE, owner.address)).to.equal(true);

      expect(await token.isTaxExempt(owner.address)).to.equal(true);
      expect(await token.isTaxExempt(feeReceiver.address)).to.equal(true);
      expect(await token.isDividendExcluded(feeReceiver.address)).to.equal(true);
    });
  });

  describe("ERC314 流动性", function () {
    it("管理员可以添加 ERC314 内置池子流动性", async function () {
      const { token } = await loadFixture(addErc314LiquidityFixture);

      expect(await token.erc314TokenReserve()).to.equal(ERC314_TOKEN_LIQUIDITY);
      expect(await token.erc314NativeReserve()).to.equal(ERC314_NATIVE_LIQUIDITY);

      expect(await ethers.provider.getBalance(await token.getAddress())).to.equal(
        ERC314_NATIVE_LIQUIDITY
      );

      expect(await token.balanceOf(await token.getAddress())).to.equal(ERC314_TOKEN_LIQUIDITY);
    });

    it("非流动性管理员不能添加 ERC314 流动性", async function () {
      const { alice, token } = await loadFixture(deployFixture);
      const tokenAddress = await token.getAddress();

      await token.transfer(alice.address, ethers.parseEther("1000"));

      await token.connect(alice).approve(tokenAddress, ethers.parseEther("1000"));

      await expect(
        token.connect(alice).addErc314Liquidity(ethers.parseEther("1000"), {
          value: ethers.parseEther("1"),
        })
      ).to.be.reverted;
    });
  });

  describe("ERC314 买入", function () {
    it("白名单阶段，非白名单用户不能买入", async function () {
      const { alice, token } = await loadFixture(addErc314LiquidityFixture);

      await expect(
        token.connect(alice).erc314Buy(0, {
          value: ethers.parseEther("1"),
        })
      ).to.be.revertedWith("erc314 buy not whitelisted");
    });

    it("白名单用户可以买入，并且买税生效", async function () {
      const { owner, feeReceiver, alice, token } = await loadFixture(addErc314LiquidityFixture);

      // 设置买税 5%
      await token.setTaxes(500, 0, 0);

      // 设置 alice 为 ERC314 买入白名单
      await token.setErc314WhitelistBuy(alice.address, true);

      const buyValue = ethers.parseEther("1");

      const preview = await token.previewErc314BuyNet(alice.address, buyValue);
      const grossTokenOut = preview[0];
      const taxAmount = preview[1];
      const netTokenOut = preview[2];

      expect(grossTokenOut).to.be.gt(0);
      expect(taxAmount).to.be.gt(0);
      expect(netTokenOut).to.equal(grossTokenOut - taxAmount);

      await expect(
        token.connect(alice).erc314Buy(netTokenOut, {
          value: buyValue,
        })
      )
        .to.emit(token, "Erc314Buy")
        .withArgs(alice.address, buyValue, grossTokenOut, netTokenOut);

      expect(await token.balanceOf(alice.address)).to.equal(netTokenOut);
      expect(await token.balanceOf(feeReceiver.address)).to.equal(taxAmount);

      // 储备应更新
      expect(await token.erc314NativeReserve()).to.equal(ERC314_NATIVE_LIQUIDITY + buyValue);
      expect(await token.erc314TokenReserve()).to.equal(ERC314_TOKEN_LIQUIDITY - grossTokenOut);
    });

    it("ERC314 买入滑点保护应生效", async function () {
      const { alice, token } = await loadFixture(addErc314LiquidityFixture);

      await token.setErc314WhitelistBuy(alice.address, true);

      const buyValue = ethers.parseEther("1");

      const preview = await token.previewErc314BuyNet(alice.address, buyValue);
      const netTokenOut = preview[2];

      await expect(
        token.connect(alice).erc314Buy(netTokenOut + 1n, {
          value: buyValue,
        })
      ).to.be.revertedWith("erc314 slippage");
    });

    it("公开阶段普通用户不能直接转 ETH 到合约，必须调用 erc314Buy", async function () {
      const { alice, token } = await loadFixture(addErc314LiquidityFixture);

      await token.setPublicErc314SwapEnabled(true);

      await expect(
        alice.sendTransaction({
          to: await token.getAddress(),
          value: ethers.parseEther("1"),
        })
      ).to.be.revertedWith("direct ETH disabled; use erc314Buy");
    });
  });

  describe("ERC314 卖出", function () {
    async function buyerHasTokensFixture() {
      const base = await addErc314LiquidityFixture();
      const { alice, token } = base;

      await token.setTaxes(0, 500, 0);

      await token.setErc314WhitelistBuy(alice.address, true);
      await token.setErc314WhitelistSell(alice.address, true);

      await token.connect(alice).erc314Buy(0, {
        value: ethers.parseEther("1"),
      });

      return base;
    }

    it("白名单用户可以卖出，并且卖税生效", async function () {
      const { alice, feeReceiver, token } = await loadFixture(buyerHasTokensFixture);

      const sellerBalance = await token.balanceOf(alice.address);
      const sellAmount = sellerBalance / 2n;

      const preview = await token.previewErc314SellNet(alice.address, sellAmount);
      const taxAmount = preview[1];
      const netTokenIn = preview[2];
      const nativeOut = preview[3];

      expect(taxAmount).to.be.gt(0);
      expect(netTokenIn).to.equal(sellAmount - taxAmount);
      expect(nativeOut).to.be.gt(0);

      const tokenAddress = await token.getAddress();
      const contractEthBefore = await ethers.provider.getBalance(tokenAddress);

      await expect(token.connect(alice).erc314Sell(sellAmount, nativeOut))
        .to.emit(token, "Erc314Sell")
        .withArgs(alice.address, sellAmount, netTokenIn, nativeOut);

      const contractEthAfter = await ethers.provider.getBalance(tokenAddress);

      expect(contractEthBefore - contractEthAfter).to.equal(nativeOut);
      expect(await token.balanceOf(feeReceiver.address)).to.equal(taxAmount);
    });

    it("ERC314 卖出滑点保护应生效", async function () {
      const { alice, token } = await loadFixture(buyerHasTokensFixture);

      const sellerBalance = await token.balanceOf(alice.address);
      const sellAmount = sellerBalance / 2n;

      const preview = await token.previewErc314SellNet(alice.address, sellAmount);
      const nativeOut = preview[3];

      await expect(
        token.connect(alice).erc314Sell(sellAmount, nativeOut + 1n)
      ).to.be.revertedWith("erc314 slippage");
    });

    it("默认关闭 transfer(address(this), amount) 自动卖出", async function () {
      const { alice, token } = await loadFixture(buyerHasTokensFixture);

      const sellerBalance = await token.balanceOf(alice.address);
      const sellAmount = sellerBalance / 2n;

      // 默认关闭时，这只是普通转账到合约，不触发 ERC314 卖出
      await token.connect(alice).transfer(await token.getAddress(), sellAmount);

      expect(await token.balanceOf(await token.getAddress())).to.be.gt(ERC314_TOKEN_LIQUIDITY);
    });
  });

  describe("普通转账税和冻结", function () {
    it("普通转账税应生效", async function () {
      const { owner, feeReceiver, alice, token } = await loadFixture(deployFixture);

      // owner 默认免税，先取消 owner 免税
      await token.setTaxExempt(owner.address, false);

      // 普通转账税 1%
      await token.setTaxes(0, 0, 100);

      const amount = ethers.parseEther("1000");
      const fee = amount / 100n;
      const receiveAmount = amount - fee;

      await token.transfer(alice.address, amount);

      expect(await token.balanceOf(alice.address)).to.equal(receiveAmount);
      expect(await token.balanceOf(feeReceiver.address)).to.equal(fee);
    });

    it("冻结账户不能转出，也不能接收", async function () {
      const { owner, alice, bob, token } = await loadFixture(deployFixture);

      await token.transfer(alice.address, ethers.parseEther("1000"));

      await token.setFrozen(alice.address, true);

      await expect(
        token.connect(alice).transfer(bob.address, ethers.parseEther("1"))
      ).to.be.revertedWith("from frozen");

      await expect(
        token.transfer(alice.address, ethers.parseEther("1"))
      ).to.be.revertedWith("to frozen");
    });

    it("暂停后普通转账应失败，恢复后可转账", async function () {
      const { alice, token } = await loadFixture(deployFixture);

      await token.pause();

      await expect(
        token.transfer(alice.address, ethers.parseEther("1"))
      ).to.be.revertedWith("token paused");

      await token.unpause();

      await token.transfer(alice.address, ethers.parseEther("1"));

      expect(await token.balanceOf(alice.address)).to.equal(ethers.parseEther("1"));
    });
  });

  describe("分红", function () {
    it("可以发放和领取分红", async function () {
      const { owner, rewardToken, token } = await loadFixture(deployFixture);

      const tokenAddress = await token.getAddress();

      const dividendAmount = ethers.parseEther("1000");

      await rewardToken.approve(tokenAddress, dividendAmount);

      await expect(token.distributeDividends(dividendAmount))
        .to.emit(token, "DividendsDistributed")
        .withArgs(owner.address, dividendAmount);

      expect(await token.pendingDividendOf(owner.address)).to.equal(dividendAmount);

      await expect(token.claimDividends())
        .to.emit(token, "DividendsClaimed")
        .withArgs(owner.address, dividendAmount);

      expect(await token.pendingDividendOf(owner.address)).to.equal(0);
      expect(await token.totalDividendsClaimed()).to.equal(dividendAmount);
    });

    it("单次分红超过上限应失败", async function () {
      const { owner, rewardToken, token } = await loadFixture(deployFixture);

      const tokenAddress = await token.getAddress();

      await token.setMaxDividendDistributionAmount(ethers.parseEther("100"));

      const tooLargeAmount = ethers.parseEther("101");

      await rewardToken.approve(tokenAddress, tooLargeAmount);

      await expect(
        token.distributeDividends(tooLargeAmount)
      ).to.be.revertedWith("dividend too large");
    });

    it("排除分红账户后不参与分红", async function () {
      const { owner, alice, rewardToken, token } = await loadFixture(deployFixture);

      const tokenAddress = await token.getAddress();

      await token.transfer(alice.address, ethers.parseEther("1000"));

      await token.setDividendExcluded(alice.address, true);

      const dividendAmount = ethers.parseEther("1000");

      await rewardToken.approve(tokenAddress, dividendAmount);

      await token.distributeDividends(dividendAmount);

      expect(await token.pendingDividendOf(alice.address)).to.equal(0);
      expect(await token.pendingDividendOf(owner.address)).to.equal(dividendAmount);
    });
  });

  describe("救援功能", function () {
    it("rescueETH 只能提取超过 ERC314 储备之外的 ETH", async function () {
      const { owner, treasury, token } = await loadFixture(addErc314LiquidityFixture);

      // 直接给合约额外转 1 ETH，模拟误转
      await owner.sendTransaction({
        to: await token.getAddress(),
        value: ethers.parseEther("1"),
      });

      await expect(
        token.rescueETH(treasury.address, ethers.parseEther("1"))
      ).to.emit(token, "RescueETH");

      // 不能提 ERC314 储备里的 ETH
      await expect(
        token.rescueETH(treasury.address, 1)
      ).to.be.revertedWith("reserved native");
    });

    it("rescueToken 不能救援本币", async function () {
      const { treasury, token } = await loadFixture(deployFixture);

      await expect(
        token.rescueToken(await token.getAddress(), treasury.address, 1)
      ).to.be.revertedWith("cannot rescue self token");
    });

    it("rewardToken 只能救援超过用户未领取分红之外的多余部分", async function () {
      const { owner, treasury, rewardToken, token } = await loadFixture(deployFixture);

      const tokenAddress = await token.getAddress();

      const dividendAmount = ethers.parseEther("100");
      const extraAmount = ethers.parseEther("10");

      // 发放 100 分红
      await rewardToken.approve(tokenAddress, dividendAmount);
      await token.distributeDividends(dividendAmount);

      expect(await token.reservedRewardBalance()).to.equal(dividendAmount);
      expect(await token.rescueableRewardTokenAmount()).to.equal(0);

      // 额外误转 10 个 rewardToken
      await rewardToken.transfer(tokenAddress, extraAmount);

      expect(await token.rescueableRewardTokenAmount()).to.equal(extraAmount);

      // 不能救援超过超额部分
      await expect(
        token.rescueToken(await rewardToken.getAddress(), treasury.address, extraAmount + 1n)
      ).to.be.revertedWith("reserved reward");

      // 可以救援超额部分
      await expect(
        token.rescueToken(await rewardToken.getAddress(), treasury.address, extraAmount)
      ).to.emit(token, "RescueToken");

      expect(await token.rescueableRewardTokenAmount()).to.equal(0);

      // 用户仍然可以领取自己的分红
      await token.claimDividends();

      expect(await token.totalDividendsClaimed()).to.equal(dividendAmount);
    });
  });

  describe("ERC314 储备同步", function () {
    it("单次同步偏差不能超过 5%，并且有冷却时间", async function () {
      const { token } = await loadFixture(addErc314LiquidityFixture);

      // 第一次同步：降低 4%，允许
      const tokenReserve1 = ethers.parseEther("96000");
      const nativeReserve1 = ethers.parseEther("9.6");

      await expect(token.syncErc314Reserves(tokenReserve1, nativeReserve1))
        .to.emit(token, "Erc314ReservesSynced")
        .withArgs(tokenReserve1, nativeReserve1);

      // 立即再次同步，应因冷却失败
      await expect(
        token.syncErc314Reserves(ethers.parseEther("95000"), ethers.parseEther("9.5"))
      ).to.be.revertedWith("reserve sync cooling down");

      // 等待 12 小时以上
      await time.increase(12 * 60 * 60 + 1);

      // 偏差过大，应失败
      await expect(
        token.syncErc314Reserves(ethers.parseEther("80000"), ethers.parseEther("8"))
      ).to.be.revertedWith("reserve sync deviation too high");
    });

    it("可以设置储备同步冷却时间", async function () {
      const { token } = await loadFixture(deployFixture);

      await expect(token.setErc314ReserveSyncCooldown(3600))
        .to.emit(token, "Erc314ReserveSyncCooldownUpdated")
        .withArgs(12 * 60 * 60, 3600);

      expect(await token.erc314ReserveSyncCooldown()).to.equal(3600);
    });
  });

  describe("Router 和 Pair 管理", function () {
    it("部署时传入 Router 会自动创建 mainPair", async function () {
      const { token, weth, factory1 } = await loadFixture(deployWithRouterFixture);

      const pair = await factory1.getPair(await token.getAddress(), await weth.getAddress());

      expect(pair).to.not.equal(ethers.ZeroAddress);
      expect(await token.mainPair()).to.equal(pair);
      expect(await token.isAmmPair(pair)).to.equal(true);
    });

    it("更新 Router 时可以选择清理旧 mainPair 标记", async function () {
      const { token, weth, factory1, factory2, router2 } = await loadFixture(deployWithRouterFixture);

      const tokenAddress = await token.getAddress();
      const wethAddress = await weth.getAddress();

      const oldPair = await factory1.getPair(tokenAddress, wethAddress);

      expect(await token.isAmmPair(oldPair)).to.equal(true);

      await expect(
        token["setRouter(address,bool)"](await router2.getAddress(), true)
      ).to.emit(token, "RouterUpdated");

      const newPair = await factory2.getPair(tokenAddress, wethAddress);

      expect(newPair).to.not.equal(ethers.ZeroAddress);
      expect(newPair).to.not.equal(oldPair);

      expect(await token.mainPair()).to.equal(newPair);
      expect(await token.isAmmPair(newPair)).to.equal(true);
      expect(await token.isAmmPair(oldPair)).to.equal(false);
    });
  });

  describe("白名单和公开开关", function () {
    it("ERC314 公开后，普通用户可以通过 erc314Buy 买入", async function () {
      const { alice, token } = await loadFixture(addErc314LiquidityFixture);

      await token.setPublicErc314SwapEnabled(true);

      const preview = await token.previewErc314BuyNet(alice.address, ethers.parseEther("1"));
      const minOut = preview[2];

      await token.connect(alice).erc314Buy(minOut, {
        value: ethers.parseEther("1"),
      });

      expect(await token.balanceOf(alice.address)).to.equal(minOut);
    });

    it("批量白名单长度超过上限应失败", async function () {
      const { owner, token } = await loadFixture(deployFixture);

      const accounts = [];

      for (let i = 0; i < 201; i++) {
        accounts.push(owner.address);
      }

      await expect(
        token.batchSetErc314WhitelistBuy(accounts, true)
      ).to.be.revertedWith("batch too large");
    });
  });
});
