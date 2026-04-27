
const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture } = require("@nomicfoundation/hardhat-network-helpers");

const ERC1271_MAGIC = "0x1626ba7e";
const ERC1271_INVALID = "0xffffffff";

function signRawHash(wallet, hash) {
  const sig = wallet.signingKey.sign(hash);
  return ethers.Signature.from(sig).serialized;
}

function makeSalt(n = 1) {
  return ethers.toBeHex(n, 32);
}

function encodeCallHash(calls) {
  return ethers.keccak256(
    ethers.AbiCoder.defaultAbiCoder().encode(
      ["tuple(address target,uint256 value,bytes data)[]"],
      [calls]
    )
  );
}

function makePackedUserOp(sender, signature = "0x") {
  return {
    sender,
    nonce: 0n,
    initCode: "0x",
    callData: "0x",
    accountGasLimits: ethers.ZeroHash,
    preVerificationGas: 0n,
    gasFees: ethers.ZeroHash,
    paymasterAndData: "0x",
    signature,
  };
}

describe("My4337SmartAccount", function () {
  async function deployFixture() {
    const [deployer, receiver, other] = await ethers.getSigners();

    const ownerWallet = ethers.Wallet.createRandom();
    const newOwnerWallet = ethers.Wallet.createRandom();
    const wrongWallet = ethers.Wallet.createRandom();

    const MockEntryPoint = await ethers.getContractFactory("MockEntryPoint");
    const entryPoint = await MockEntryPoint.deploy();
    await entryPoint.waitForDeployment();

    const Factory = await ethers.getContractFactory("My4337SmartAccountFactory");
    const factory = await Factory.deploy(await entryPoint.getAddress());
    await factory.waitForDeployment();

    const MockTarget = await ethers.getContractFactory("MockTarget");
    const target = await MockTarget.deploy();
    await target.waitForDeployment();

    const MockERC721 = await ethers.getContractFactory("MockERC721");
    const erc721 = await MockERC721.deploy();
    await erc721.waitForDeployment();

    const MockERC1155 = await ethers.getContractFactory("MockERC1155");
    const erc1155 = await MockERC1155.deploy();
    await erc1155.waitForDeployment();

    const salt = makeSalt(1);

    const accountAddress = await factory["getAddress(address,bytes32)"](
      ownerWallet.address,
      salt
    );

    await factory.createAccount(ownerWallet.address, salt);

    const account = await ethers.getContractAt(
      "My4337SmartAccount",
      accountAddress
    );

    return {
      deployer,
      receiver,
      other,
      ownerWallet,
      newOwnerWallet,
      wrongWallet,
      entryPoint,
      factory,
      account,
      accountAddress,
      target,
      erc721,
      erc1155,
      salt,
    };
  }

  describe("Factory 部署和基础信息", function () {
    it("部署 Factory 时应正确保存 EntryPoint、implementation 和版本号", async function () {
      const { factory, entryPoint } = await loadFixture(deployFixture);

      expect(await factory.entryPoint()).to.equal(await entryPoint.getAddress());
      expect(await factory.implementation()).to.not.equal(ethers.ZeroAddress);
      expect(await factory.version()).to.equal("1.0.0");
      expect(await factory.FACTORY_VERSION()).to.equal("1.0.0");
    });

    it("部署 Factory 时 EntryPoint 不能是 0 地址", async function () {
      const Factory = await ethers.getContractFactory(
        "My4337SmartAccountFactory"
      );

      await expect(
        Factory.deploy(ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(
        Factory,
        "FactoryEntryPointZeroAddress"
      );
    });

    it("implementation 应该被锁定，不能被直接 initialize", async function () {
      const { factory, ownerWallet } = await loadFixture(deployFixture);

      const implementationAddress = await factory.implementation();

      const implementation = await ethers.getContractAt(
        "My4337SmartAccount",
        implementationAddress
      );

      await expect(
        implementation.initialize(ownerWallet.address)
      ).to.be.reverted;
    });
  });

  describe("Factory CREATE2、initCode 和幂等创建", function () {
    it("getAddress 应该稳定返回同一个反事实地址", async function () {
      const { factory, ownerWallet, salt, accountAddress } =
        await loadFixture(deployFixture);

      const again = await factory["getAddress(address,bytes32)"](
        ownerWallet.address,
        salt
      );

      expect(again).to.equal(accountAddress);
    });

    it("owner 为 0 地址时，Factory 函数应 revert", async function () {
      const { factory, salt } = await loadFixture(deployFixture);

      await expect(
        factory["getAddress(address,bytes32)"](ethers.ZeroAddress, salt)
      ).to.be.revertedWithCustomError(factory, "FactoryOwnerZeroAddress");

      await expect(
        factory.getInitCode(ethers.ZeroAddress, salt)
      ).to.be.revertedWithCustomError(factory, "FactoryOwnerZeroAddress");

      await expect(
        factory.getInitCodeIfNeeded(ethers.ZeroAddress, salt)
      ).to.be.revertedWithCustomError(factory, "FactoryOwnerZeroAddress");

      await expect(
        factory.createAccount(ethers.ZeroAddress, salt)
      ).to.be.revertedWithCustomError(factory, "FactoryOwnerZeroAddress");
    });

    it("createAccount 应初始化 owner，并且重复调用不重复部署、不重复 emit", async function () {
      const {
        factory,
        ownerWallet,
        account,
        accountAddress,
        salt,
        entryPoint,
      } = await loadFixture(deployFixture);

      expect(await account.owner()).to.equal(ownerWallet.address);
      expect(await account.entryPoint()).to.equal(await entryPoint.getAddress());
      expect(await account.version()).to.equal("1.0.0");
      expect(await account.ACCOUNT_VERSION()).to.equal("1.0.0");

      const code = await ethers.provider.getCode(accountAddress);
      expect(code).to.not.equal("0x");

      await expect(
        factory.createAccount(ownerWallet.address, salt)
      ).to.not.emit(factory, "AccountCreated");

      expect(await account.owner()).to.equal(ownerWallet.address);
    });

    it("getInitCode 应返回 factory 地址 + createAccount calldata", async function () {
      const { factory, ownerWallet, salt } = await loadFixture(deployFixture);

      const factoryAddress = await factory.getAddress();

      const expectedCreateData = factory.interface.encodeFunctionData(
        "createAccount",
        [ownerWallet.address, salt]
      );

      const expectedInitCode = factoryAddress + expectedCreateData.slice(2);

      const initCode = await factory.getInitCode(ownerWallet.address, salt);

      expect(initCode).to.equal(expectedInitCode);
    });

    it("getInitCodeIfNeeded：账户已部署时应返回空 bytes", async function () {
      const { factory, ownerWallet, salt } = await loadFixture(deployFixture);

      const initCode = await factory.getInitCodeIfNeeded(
        ownerWallet.address,
        salt
      );

      expect(initCode).to.equal("0x");
    });

    it("getInitCodeIfNeeded：账户未部署时应返回 initCode", async function () {
      const { factory } = await loadFixture(deployFixture);

      const freshOwner = ethers.Wallet.createRandom();
      const freshSalt = makeSalt(999);

      const initCode = await factory.getInitCodeIfNeeded(
        freshOwner.address,
        freshSalt
      );

      const alwaysInitCode = await factory.getInitCode(
        freshOwner.address,
        freshSalt
      );

      expect(initCode).to.equal(alwaysInitCode);
      expect(initCode).to.not.equal("0x");
    });
  });

  describe("账户收 ETH、nonce 和 ERC165", function () {
    it("账户应能直接接收 ETH", async function () {
      const { deployer, accountAddress } = await loadFixture(deployFixture);

      const amount = ethers.parseEther("1");

      await deployer.sendTransaction({
        to: accountAddress,
        value: amount,
      });

      expect(await ethers.provider.getBalance(accountAddress)).to.equal(amount);
    });

    it("getNonce 应从 EntryPoint 读取 nonce", async function () {
      const { entryPoint, account, accountAddress } =
        await loadFixture(deployFixture);

      await entryPoint.setNonce(accountAddress, 0, 123);
      await entryPoint.setNonce(accountAddress, 7, 456);

      expect(await account["getNonce()"]()).to.equal(123n);
      expect(await account).to.equal(456n);
    });

    it("supportsInterface 应支持 ERC-1271", async function () {
      const { account } = await loadFixture(deployFixture);

      expect(await account.supportsInterface(ERC1271_MAGIC)).to.equal(true);
      expect(await account.supportsInterface("0xffffffff")).to.equal(false);
    });
  });

  describe("execute 单笔调用", function () {
    it("非 EntryPoint / 非账户自己调用 execute 应 revert", async function () {
      const { account, target, deployer } = await loadFixture(deployFixture);

      const targetData = target.interface.encodeFunctionData("setNumber", [
        123,
      ]);

      await expect(
        account.connect(deployer).execute(await target.getAddress(), 0, targetData)
      )
        .to.be.revertedWithCustomError(account, "AccountUnauthorized")
        .withArgs(deployer.address);
    });

    it("EntryPoint 应能通过 execute 调目标合约", async function () {
      const { entryPoint, account, accountAddress, target } =
        await loadFixture(deployFixture);

      const targetAddress = await target.getAddress();

      const targetData = target.interface.encodeFunctionData("setNumber", [
        123,
      ]);

      const executeData = account.interface.encodeFunctionData("execute", [
        targetAddress,
        0,
        targetData,
      ]);

      await expect(
        entryPoint.executeFromAccount(accountAddress, executeData)
      )
        .to.emit(account, "Executed")
        .withArgs(targetAddress, 0, ethers.keccak256(targetData));

      expect(await target.number()).to.equal(123n);
      expect(await target.lastSender()).to.equal(accountAddress);
      expect(await target.lastValue()).to.equal(0n);
    });

    it("execute 应能从账户余额往外转 ETH", async function () {
      const {
        deployer,
        receiver,
        entryPoint,
        account,
        accountAddress,
      } = await loadFixture(deployFixture);

      const amount = ethers.parseEther("0.25");

      await deployer.sendTransaction({
        to: accountAddress,
        value: amount,
      });

      const before = await ethers.provider.getBalance(receiver.address);

      const executeData = account.interface.encodeFunctionData("execute", [
        receiver.address,
        amount,
        "0x",
      ]);

      await entryPoint.executeFromAccount(accountAddress, executeData);

      const after = await ethers.provider.getBalance(receiver.address);

      expect(after - before).to.equal(amount);
      expect(await ethers.provider.getBalance(accountAddress)).to.equal(0n);
    });

    it("execute 不是 payable，EntryPoint 不能带 msg.value 调用 execute", async function () {
      const { entryPoint, account, accountAddress, target } =
        await loadFixture(deployFixture);

      const targetData = target.interface.encodeFunctionData("setNumber", [
        1,
      ]);

      const executeData = account.interface.encodeFunctionData("execute", [
        await target.getAddress(),
        0,
        targetData,
      ]);

      await expect(
        entryPoint.executeFromAccountWithValue(accountAddress, executeData, {
          value: 1n,
        })
      ).to.be.reverted;
    });

    it("execute 的 target 不能是 0 地址", async function () {
      const { entryPoint, account, accountAddress } =
        await loadFixture(deployFixture);

      const executeData = account.interface.encodeFunctionData("execute", [
        ethers.ZeroAddress,
        0,
        "0x",
      ]);

      await expect(
        entryPoint.executeFromAccount(accountAddress, executeData)
      ).to.be.revertedWithCustomError(account, "SmartAccountInvalidTarget");
    });

    it("execute 应原样冒泡目标合约 revert reason", async function () {
      const { entryPoint, account, accountAddress, target } =
        await loadFixture(deployFixture);

      const targetData =
        target.interface.encodeFunctionData("revertWithMessage");

      const executeData = account.interface.encodeFunctionData("execute", [
        await target.getAddress(),
        0,
        targetData,
      ]);

      await expect(
        entryPoint.executeFromAccount(accountAddress, executeData)
      ).to.be.revertedWith("MOCK_TARGET_REVERT");
    });

    it("execute 应返回目标合约 returnData", async function () {
      const { entryPoint, account, accountAddress, target } =
        await loadFixture(deployFixture);

      const targetData = target.interface.encodeFunctionData("add", [2, 3]);

      const executeData = account.interface.encodeFunctionData("execute", [
        await target.getAddress(),
        0,
        targetData,
      ]);

      const rawAccountReturn =
        await entryPoint.executeFromAccount.staticCall(
          accountAddress,
          executeData
        );

      const [targetReturnData] = account.interface.decodeFunctionResult(
        "execute",
        rawAccountReturn
      );

      const [sum] = target.interface.decodeFunctionResult(
        "add",
        targetReturnData
      );

      expect(sum).to.equal(5n);
    });
  });

  describe("executeBatch 批量调用", function () {
    it("EntryPoint 应能批量执行多笔调用，并 emit callsHash", async function () {
      const { entryPoint, account, accountAddress, target } =
        await loadFixture(deployFixture);

      const targetAddress = await target.getAddress();

      const data1 = target.interface.encodeFunctionData("setNumber", [11]);
      const data2 = target.interface.encodeFunctionData("setNumber", [22]);

      const calls = [
        [targetAddress, 0, data1],
        [targetAddress, 0, data2],
      ];

      const callsHash = encodeCallHash(calls);

      const batchData = account.interface.encodeFunctionData("executeBatch", [
        calls,
      ]);

      await expect(
        entryPoint.executeFromAccount(accountAddress, batchData)
      )
        .to.emit(account, "BatchExecuted")
        .withArgs(2, callsHash);

      expect(await target.number()).to.equal(22n);
      expect(await target.lastSender()).to.equal(accountAddress);
    });

    it("executeBatch 空数组应 revert", async function () {
      const { entryPoint, account, accountAddress } =
        await loadFixture(deployFixture);

      const batchData = account.interface.encodeFunctionData("executeBatch", [
        [],
      ]);

      await expect(
        entryPoint.executeFromAccount(accountAddress, batchData)
      ).to.be.revertedWithCustomError(account, "SmartAccountEmptyBatch");
    });

    it("executeBatch 超过 MAX_BATCH_SIZE 应 revert", async function () {
      const { entryPoint, account, accountAddress, target } =
        await loadFixture(deployFixture);

      const targetAddress = await target.getAddress();
      const data = target.interface.encodeFunctionData("add", [1, 2]);

      const calls = Array.from({ length: 33 }, () => [
        targetAddress,
        0,
        data,
      ]);

      const batchData = account.interface.encodeFunctionData("executeBatch", [
        calls,
      ]);

      await expect(
        entryPoint.executeFromAccount(accountAddress, batchData)
      )
        .to.be.revertedWithCustomError(account, "SmartAccountBatchTooLarge")
        .withArgs(33, 32);
    });

    it("executeBatch 中任意一笔失败，整个 batch 应回滚", async function () {
      const { entryPoint, account, accountAddress, target } =
        await loadFixture(deployFixture);

      const targetAddress = await target.getAddress();

      const okData = target.interface.encodeFunctionData("setNumber", [999]);
      const badData =
        target.interface.encodeFunctionData("revertWithMessage");

      const calls = [
        [targetAddress, 0, okData],
        [targetAddress, 0, badData],
      ];

      const batchData = account.interface.encodeFunctionData("executeBatch", [
        calls,
      ]);

      await expect(
        entryPoint.executeFromAccount(accountAddress, batchData)
      ).to.be.revertedWith("MOCK_TARGET_REVERT");

      expect(await target.number()).to.equal(0n);
    });
  });

  describe("changeOwner", function () {
    it("非 EntryPoint / 非账户自己调用 changeOwner 应 revert", async function () {
      const { account, deployer, newOwnerWallet } =
        await loadFixture(deployFixture);

      await expect(
        account.connect(deployer).changeOwner(newOwnerWallet.address)
      )
        .to.be.revertedWithCustomError(account, "AccountUnauthorized")
        .withArgs(deployer.address);
    });

    it("EntryPoint 应能更换 owner", async function () {
      const {
        entryPoint,
        account,
        accountAddress,
        ownerWallet,
        newOwnerWallet,
      } = await loadFixture(deployFixture);

      const changeData = account.interface.encodeFunctionData("changeOwner", [
        newOwnerWallet.address,
      ]);

      await expect(
        entryPoint.executeFromAccount(accountAddress, changeData)
      )
        .to.emit(account, "OwnerChanged")
        .withArgs(ownerWallet.address, newOwnerWallet.address);

      expect(await account.owner()).to.equal(newOwnerWallet.address);
    });

    it("不能把 owner 改成 0 地址", async function () {
      const { entryPoint, account, accountAddress } =
        await loadFixture(deployFixture);

      const changeData = account.interface.encodeFunctionData("changeOwner", [
        ethers.ZeroAddress,
      ]);

      await expect(
        entryPoint.executeFromAccount(accountAddress, changeData)
      ).to.be.revertedWithCustomError(account, "SmartAccountZeroAddress");
    });

    it("不能把 owner 改成当前 owner", async function () {
      const { entryPoint, account, accountAddress, ownerWallet } =
        await loadFixture(deployFixture);

      const changeData = account.interface.encodeFunctionData("changeOwner", [
        ownerWallet.address,
      ]);

      await expect(
        entryPoint.executeFromAccount(accountAddress, changeData)
      )
        .to.be.revertedWithCustomError(account, "SmartAccountOwnerUnchanged")
        .withArgs(ownerWallet.address);
    });

    it("账户通过 execute 调自己时，应走 onlyEntryPointOrSelf 的 self 路径", async function () {
      const {
        entryPoint,
        account,
        accountAddress,
        ownerWallet,
        newOwnerWallet,
      } = await loadFixture(deployFixture);

      const innerChangeOwner = account.interface.encodeFunctionData(
        "changeOwner",
        [newOwnerWallet.address]
      );

      const outerExecute = account.interface.encodeFunctionData("execute", [
        accountAddress,
        0,
        innerChangeOwner,
      ]);

      await expect(
        entryPoint.executeFromAccount(accountAddress, outerExecute)
      )
        .to.emit(account, "OwnerChanged")
        .withArgs(ownerWallet.address, newOwnerWallet.address);

      expect(await account.owner()).to.equal(newOwnerWallet.address);
    });
  });

  describe("EntryPoint 押金 addDeposit / withdrawDepositTo", function () {
    it("任何人都可以通过 addDeposit 给账户充值 EntryPoint 押金", async function () {
      const { account } = await loadFixture(deployFixture);

      const amount = ethers.parseEther("1");

      await account.addDeposit({ value: amount });

      expect(await account.getDeposit()).to.equal(amount);
    });

    it("非 EntryPoint / 非账户自己不能调用 withdrawDepositTo", async function () {
      const { account, receiver, deployer } = await loadFixture(deployFixture);

      await expect(
        account.connect(deployer).withdrawDepositTo(receiver.address, 1)
      )
        .to.be.revertedWithCustomError(account, "AccountUnauthorized")
        .withArgs(deployer.address);
    });

    it("EntryPoint 应能触发账户提取押金", async function () {
      const { entryPoint, account, accountAddress, receiver } =
        await loadFixture(deployFixture);

      const deposit = ethers.parseEther("1");
      const withdrawAmount = ethers.parseEther("0.4");

      await account.addDeposit({ value: deposit });

      const beforeReceiver = await ethers.provider.getBalance(receiver.address);

      const withdrawData = account.interface.encodeFunctionData(
        "withdrawDepositTo",
        [receiver.address, withdrawAmount]
      );

      await entryPoint.executeFromAccount(accountAddress, withdrawData);

      const afterReceiver = await ethers.provider.getBalance(receiver.address);

      expect(afterReceiver - beforeReceiver).to.equal(withdrawAmount);
      expect(await account.getDeposit()).to.equal(deposit - withdrawAmount);
    });

    it("提现金额超过押金余额应 revert", async function () {
      const { entryPoint, account, accountAddress, receiver } =
        await loadFixture(deployFixture);

      const deposit = ethers.parseEther("1");
      const tooMuch = deposit + 1n;

      await account.addDeposit({ value: deposit });

      const withdrawData = account.interface.encodeFunctionData(
        "withdrawDepositTo",
        [receiver.address, tooMuch]
      );

      await expect(
        entryPoint.executeFromAccount(accountAddress, withdrawData)
      )
        .to.be.revertedWithCustomError(
          account,
          "SmartAccountInsufficientDeposit"
        )
        .withArgs(tooMuch, deposit);
    });

    it("提现接收地址不能是 0 地址", async function () {
      const { entryPoint, account, accountAddress } =
        await loadFixture(deployFixture);

      await account.addDeposit({ value: ethers.parseEther("1") });

      const withdrawData = account.interface.encodeFunctionData(
        "withdrawDepositTo",
        [ethers.ZeroAddress, 1]
      );

      await expect(
        entryPoint.executeFromAccount(accountAddress, withdrawData)
      ).to.be.revertedWithCustomError(account, "SmartAccountZeroAddress");
    });
  });

  describe("ERC-1271 标准签名校验", function () {
    it("isValidSignature：owner 对裸 hash 的原始签名应有效", async function () {
      const { account, ownerWallet } = await loadFixture(deployFixture);

      const hash = ethers.keccak256(
        ethers.toUtf8Bytes("raw hash for ERC1271")
      );

      const signature = signRawHash(ownerWallet, hash);

      expect(await account.isValidSignature(hash, signature)).to.equal(
        ERC1271_MAGIC
      );
    });

    it("isValidSignature：错误 signer 的签名应无效", async function () {
      const { account, wrongWallet } = await loadFixture(deployFixture);

      const hash = ethers.keccak256(
        ethers.toUtf8Bytes("raw hash for ERC1271")
      );

      const signature = signRawHash(wrongWallet, hash);

      expect(await account.isValidSignature(hash, signature)).to.equal(
        ERC1271_INVALID
      );
    });

    it("更换 owner 后，旧 owner 签名应失效，新 owner 签名应有效", async function () {
      const {
        entryPoint,
        account,
        accountAddress,
        ownerWallet,
        newOwnerWallet,
      } = await loadFixture(deployFixture);

      const changeData = account.interface.encodeFunctionData("changeOwner", [
        newOwnerWallet.address,
      ]);

      await entryPoint.executeFromAccount(accountAddress, changeData);

      const hash = ethers.keccak256(
        ethers.toUtf8Bytes("after owner changed")
      );

      const oldSignature = signRawHash(ownerWallet, hash);
      const newSignature = signRawHash(newOwnerWallet, hash);

      expect(await account.isValidSignature(hash, oldSignature)).to.equal(
        ERC1271_INVALID
      );

      expect(await account.isValidSignature(hash, newSignature)).to.equal(
        ERC1271_MAGIC
      );
    });
  });

  describe("严格 EIP-712 replay-safe 验签", function () {
    async function buildTypedData(accountAddress, entryPointAddress, appHash) {
      const network = await ethers.provider.getNetwork();

      const domain = {
        name: "My4337SmartAccount",
        version: "1",
        chainId: network.chainId,
        verifyingContract: accountAddress,
      };

      const types = {
        ERC1271ReplaySafeMessage: [
          { name: "entryPoint", type: "address" },
          { name: "appHash", type: "bytes32" },
        ],
      };

      const message = {
        entryPoint: entryPointAddress,
        appHash,
      };

      return { domain, types, message };
    }

    it("erc1271ReplaySafeHash 应和前端 TypedDataEncoder 计算结果一致", async function () {
      const { account, accountAddress, entryPoint } =
        await loadFixture(deployFixture);

      const appHash = ethers.keccak256(
        ethers.toUtf8Bytes("business hash with nonce/deadline")
      );

      const { domain, types, message } = await buildTypedData(
        accountAddress,
        await entryPoint.getAddress(),
        appHash
      );

      const expectedDigest = ethers.TypedDataEncoder.hash(
        domain,
        types,
        message
      );

      expect(await account.erc1271ReplaySafeHash(appHash)).to.equal(
        expectedDigest
      );
    });

    it("isValidReplaySafeSignature 应验证 owner 的 EIP-712 签名", async function () {
      const { account, accountAddress, entryPoint, ownerWallet } =
        await loadFixture(deployFixture);

      const appHash = ethers.keccak256(
        ethers.toUtf8Bytes("appHash: orderId=1 nonce=1 deadline=999")
      );

      const { domain, types, message } = await buildTypedData(
        accountAddress,
        await entryPoint.getAddress(),
        appHash
      );

      const signature = await ownerWallet.signTypedData(
        domain,
        types,
        message
      );

      expect(
        await account.isValidReplaySafeSignature(appHash, signature)
      ).to.equal(true);

      expect(
        await account.isValidReplaySafeSignature1271(appHash, signature)
      ).to.equal(ERC1271_MAGIC);
    });

    it("isValidReplaySafeSignature：错误 appHash 应无效", async function () {
      const { account, accountAddress, entryPoint, ownerWallet } =
        await loadFixture(deployFixture);

      const appHash = ethers.keccak256(ethers.toUtf8Bytes("correct appHash"));
      const wrongAppHash = ethers.keccak256(
        ethers.toUtf8Bytes("wrong appHash")
      );

      const { domain, types, message } = await buildTypedData(
        accountAddress,
        await entryPoint.getAddress(),
        appHash
      );

      const signature = await ownerWallet.signTypedData(
        domain,
        types,
        message
      );

      expect(
        await account.isValidReplaySafeSignature(wrongAppHash, signature)
      ).to.equal(false);

      expect(
        await account.isValidReplaySafeSignature1271(
          wrongAppHash,
          signature
        )
      ).to.equal(ERC1271_INVALID);
    });

    it("isValidReplaySafeSignature：错误 signer 应无效", async function () {
      const { account, accountAddress, entryPoint, wrongWallet } =
        await loadFixture(deployFixture);

      const appHash = ethers.keccak256(
        ethers.toUtf8Bytes("appHash signed by wrong wallet")
      );

      const { domain, types, message } = await buildTypedData(
        accountAddress,
        await entryPoint.getAddress(),
        appHash
      );

      const signature = await wrongWallet.signTypedData(
        domain,
        types,
        message
      );

      expect(
        await account.isValidReplaySafeSignature(appHash, signature)
      ).to.equal(false);
    });
  });

  describe("validateUserOp", function () {
    it("直接调用 validateUserOp 应被拒绝，因为 caller 不是 EntryPoint", async function () {
      const { account, deployer, accountAddress } =
        await loadFixture(deployFixture);

      const userOpHash = ethers.keccak256(ethers.toUtf8Bytes("userOpHash"));
      const userOp = makePackedUserOp(accountAddress, "0x");

      await expect(
        account.connect(deployer).validateUserOp(userOp, userOpHash, 0)
      )
        .to.be.revertedWithCustomError(account, "AccountUnauthorized")
        .withArgs(deployer.address);
    });

    it("EntryPoint 调 validateUserOp：签名正确应返回 0", async function () {
      const { entryPoint, accountAddress, ownerWallet } =
        await loadFixture(deployFixture);

      const userOpHash = ethers.keccak256(
        ethers.toUtf8Bytes("valid userOpHash")
      );

      const signature = signRawHash(ownerWallet, userOpHash);
      const userOp = makePackedUserOp(accountAddress, signature);

      const validationData =
        await entryPoint.validateAccount.staticCall(
          accountAddress,
          userOp,
          userOpHash,
          0
        );

      expect(validationData).to.equal(0n);
    });

    it("EntryPoint 调 validateUserOp：签名错误应返回 1，而不是 revert", async function () {
      const { entryPoint, accountAddress, wrongWallet } =
        await loadFixture(deployFixture);

      const userOpHash = ethers.keccak256(
        ethers.toUtf8Bytes("invalid userOpHash")
      );

      const signature = signRawHash(wrongWallet, userOpHash);
      const userOp = makePackedUserOp(accountAddress, signature);

      const validationData =
        await entryPoint.validateAccount.staticCall(
          accountAddress,
          userOp,
          userOpHash,
          0
        );

      expect(validationData).to.equal(1n);
    });

    it("validateUserOp 应向 EntryPoint 补足 missingAccountFunds", async function () {
      const {
        deployer,
        entryPoint,
        accountAddress,
        ownerWallet,
      } = await loadFixture(deployFixture);

      const missingFunds = ethers.parseEther("0.1");

      await deployer.sendTransaction({
        to: accountAddress,
        value: missingFunds,
      });

      const userOpHash = ethers.keccak256(
        ethers.toUtf8Bytes("prefund userOpHash")
      );

      const signature = signRawHash(ownerWallet, userOpHash);
      const userOp = makePackedUserOp(accountAddress, signature);

      const entryPointAddress = await entryPoint.getAddress();

      const before = await ethers.provider.getBalance(entryPointAddress);

      await entryPoint.validateAccount(
        accountAddress,
        userOp,
        userOpHash,
        missingFunds
      );

      const after = await ethers.provider.getBalance(entryPointAddress);

      expect(after - before).to.equal(missingFunds);
    });
  });

  describe("NFT 接收", function () {
    it("账户应能接收 ERC721 safeMint", async function () {
      const { accountAddress, erc721 } = await loadFixture(deployFixture);

      await erc721.safeMint(accountAddress, 1);

      expect(await erc721.ownerOf(1)).to.equal(accountAddress);
    });

    it("账户应能接收 ERC1155 mint", async function () {
      const { accountAddress, erc1155 } = await loadFixture(deployFixture);

      await erc1155.mint(accountAddress, 7, 5);

      expect(await erc1155.balanceOf(accountAddress, 7)).to.equal(5n);
    });
  });
});
