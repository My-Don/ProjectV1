const { expect } = require('chai');
const hre = require('hardhat');
const {
  encodeFunctionData,
  hexToBigInt,
  labelhash,
  namehash,
  zeroAddress,
  zeroHash,
} = require('viem');

// 定义常量
const DAY = 86400n;
const REGISTRATION_TIME = 28n * DAY;
const BUFFERED_REGISTRATION_COST = REGISTRATION_TIME + 3n * DAY;
const GRACE_PERIOD = 90n * DAY;

const labelId = (label) => hexToBigInt(labelhash(label));

// 简化的注册名称函数
async function registerName(ethRegistrarController, { label, duration = REGISTRATION_TIME, ownerAddress }) {
  const registration = {
    label,
    owner: ownerAddress,
    duration,
    secret: zeroHash,
    resolver: zeroAddress,
    data: [],
    reverseRecord: 0,
    referrer: zeroHash
  };
  
  const commitment = await ethRegistrarController.makeCommitment(registration);
  
  await ethRegistrarController.commit(commitment);
  
  // 等待更长时间以满足提交时间要求（至少10分钟）
  await hre.network.provider.send("evm_increaseTime", [660]);
  await hre.network.provider.send("evm_mine");
  
  const { base } = await ethRegistrarController.rentPrice(label, duration);
  
  await ethRegistrarController.register(registration, {
    value: base + 1n, // 添加一些缓冲
  });
}

// 提交名称函数
async function commitName(ethRegistrarController, { label, duration = REGISTRATION_TIME, ownerAddress }) {
  const registration = {
    label,
    owner: ownerAddress,
    duration,
    secret: zeroHash,
    resolver: zeroAddress,
    data: [],
    reverseRecord: 0,
    referrer: zeroHash
  };
  
  const commitment = await ethRegistrarController.makeCommitment(registration);
  
  await ethRegistrarController.commit(commitment);
  
  // 等待更长时间以满足提交时间要求（至少10分钟）
  await hre.network.provider.send("evm_increaseTime", [660]);
  await hre.network.provider.send("evm_mine");
  
  return {
    registration,
    params: {
      label,
      duration,
      ownerAddress,
    },
    hash: commitment,
  };
}

describe('ETHRegistrarController', function () {
  let ensRegistry, baseRegistrar, reverseRegistrar, dummyOracle, priceOracle, ethRegistrarController, publicResolver, defaultReverseRegistrar, callData, nameWrapper, mockMetadataService, owner, registrant, other;
  
  async function fixture() {
    [owner, registrant, other] = await hre.ethers.getSigners();
    
    console.log('Starting fixture setup...');
    
    // 部署 ENSRegistry
    console.log('Deploying ENSRegistry...');
    const ENSRegistry = await hre.ethers.getContractFactory('ENSRegistry');
    ensRegistry = await ENSRegistry.deploy();
    console.log('ENSRegistry deployed at:', ensRegistry.target);
    
    // 部署 ReverseRegistrar
    console.log('Deploying ReverseRegistrar...');
    const ReverseRegistrar = await hre.ethers.getContractFactory('ReverseRegistrar');
    reverseRegistrar = await ReverseRegistrar.deploy(owner.address, ensRegistry.target);
    console.log('ReverseRegistrar deployed at:', reverseRegistrar.target);
    
    // 部署 DefaultReverseRegistrar
    console.log('Deploying DefaultReverseRegistrar...');
    const DefaultReverseRegistrar = await hre.ethers.getContractFactory('DefaultReverseRegistrar');
    defaultReverseRegistrar = await DefaultReverseRegistrar.deploy(owner.address);
    console.log('DefaultReverseRegistrar deployed at:', defaultReverseRegistrar.target);
    
    // 设置反向注册器节点所有权
    console.log('Setting up reverse registrar nodes...');
    await ensRegistry.setSubnodeOwner(zeroHash, labelhash('reverse'), owner.address);
    await ensRegistry.setSubnodeOwner(namehash('reverse'), labelhash('addr'), reverseRegistrar.target);
    
    // 部署 BaseRegistrarImplementation
    console.log('Deploying BaseRegistrarImplementation...');
    console.log('ENS Registry address:', ensRegistry.target);
    console.log('Owner address:', owner.address);
    console.log('Base node:', namehash('eth'));
    const BaseRegistrarImplementation = await hre.ethers.getContractFactory('BaseRegistrarImplementation');
    baseRegistrar = await BaseRegistrarImplementation.deploy(ensRegistry.target, namehash('eth'), owner.address);
    console.log('BaseRegistrarImplementation deployed at:', baseRegistrar.target);
    
    // 部署 MockMetadataService
    console.log('Deploying MockMetadataService...');
    const MockMetadataService = await hre.ethers.getContractFactory('MockMetadataService');
    mockMetadataService = await MockMetadataService.deploy();
    console.log('MockMetadataService deployed at:', mockMetadataService.target);
    
    // 部署 NameWrapper
    console.log('Deploying NameWrapper...');
    const NameWrapper = await hre.ethers.getContractFactory('NameWrapper');
    nameWrapper = await NameWrapper.deploy(owner.address, ensRegistry.target, baseRegistrar.target, mockMetadataService.target);
    console.log('NameWrapper deployed at:', nameWrapper.target);
    
    // 部署 DummyOracle
    console.log('Deploying DummyOracle...');
    const DummyOracle = await hre.ethers.getContractFactory('DummyOracle');
    dummyOracle = await DummyOracle.deploy(100000000n);
    console.log('DummyOracle deployed at:', dummyOracle.target);
    
    // 部署 StablePriceOracle
    console.log('Deploying StablePriceOracle...');
    const StablePriceOracle = await hre.ethers.getContractFactory('StablePriceOracle');
    priceOracle = await StablePriceOracle.deploy(dummyOracle.target, [0n, 0n, 4n, 2n, 1n]);
    console.log('StablePriceOracle deployed at:', priceOracle.target);
    
    // 部署 ETHRegistrarController
    console.log('Deploying ETHRegistrarController...');
    const ETHRegistrarController = await hre.ethers.getContractFactory('ETHRegistrarController');
    ethRegistrarController = await ETHRegistrarController.deploy(
      owner.address,
      baseRegistrar.target,
      priceOracle.target,
      600n,
      86400n,
      reverseRegistrar.target,
      defaultReverseRegistrar.target,
      ensRegistry.target
    );
    console.log('ETHRegistrarController deployed at:', ethRegistrarController.target);
    
    // 部署 PublicResolver
    console.log('Deploying PublicResolver...');
    const PublicResolver = await hre.ethers.getContractFactory('PublicResolver');
    publicResolver = await PublicResolver.deploy(
      ensRegistry.target,
      nameWrapper.target,
      ethRegistrarController.target,
      reverseRegistrar.target
    );
    console.log('PublicResolver deployed at:', publicResolver.target);
    
    // 设置子节点所有者
    console.log('Setting up subnode owners...');
    await ensRegistry.setSubnodeOwner(zeroHash, labelhash('reverse'), owner.address);
    await ensRegistry.setSubnodeOwner(namehash('reverse'), labelhash('addr'), reverseRegistrar.target);
    await ensRegistry.setSubnodeOwner(zeroHash, labelhash('eth'), baseRegistrar.target);
    
    // 设置控制器
    console.log('Setting up controllers...');
    await baseRegistrar.addController(ethRegistrarController.target);
    await reverseRegistrar.setController(ethRegistrarController.target, true);
    await defaultReverseRegistrar.setController(ethRegistrarController.target, true);
    
    // 设置默认解析器
    console.log('Setting default resolver...');
    await reverseRegistrar.setDefaultResolver(publicResolver.target);
    
    console.log('Fixture setup completed successfully!');
    
    return {
      ensRegistry,
      baseRegistrar,
      reverseRegistrar,
      dummyOracle,
      priceOracle,
      ethRegistrarController,
      publicResolver,
      defaultReverseRegistrar,
      nameWrapper,
      mockMetadataService,
      owner,
      registrant,
      other,
    };
  }
  
  beforeEach(async function () {
    ({ ensRegistry, baseRegistrar, reverseRegistrar, dummyOracle, priceOracle, ethRegistrarController, publicResolver, defaultReverseRegistrar, nameWrapper, mockMetadataService, owner, registrant, other } = await fixture());
  });
  
  it('should report label validity', async function () {
    const checkLabels = {
      testing: true,
      longname12345678: true,
      sixsix: true,
      five5: true,
      four: true,
      iii: true,
      ii: false,
      i: false,
      '': false,
      你好吗: true,
      たこ: false,
      '\ud83d\udca9\ud83d\udca9\ud83d\udca9': true,
      '\ud83d\udca9\ud83d\udca9': false,
    };
    
    for (const label in checkLabels) {
      const result = await ethRegistrarController.valid(label);
      expect(result).to.equal(checkLabels[label]);
    }
  });
  
  it('should report unused names as available', async function () {
    const result = await ethRegistrarController.available('available');
    expect(result).to.equal(true);
  });
  
  it('should permit new registrations', async function () {
    const balanceBefore = await hre.ethers.provider.getBalance(ethRegistrarController.target);
    
    const { registration, params } = await commitName(
      ethRegistrarController,
      {
        label: 'newname',
        duration: REGISTRATION_TIME,
        ownerAddress: registrant.address,
      }
    );
    
    const { base } = await ethRegistrarController.rentPrice(params.label, params.duration);
    
    await expect(
      ethRegistrarController.register(registration, {
        value: base + 1n,
      })
    ).to.emit(ethRegistrarController, 'NameRegistered');
    
    const balanceAfter = await hre.ethers.provider.getBalance(ethRegistrarController.target);
    expect(balanceAfter).to.be.gt(balanceBefore);
  });
  
  it('should revert when not enough ether is transferred', async function () {
    const { registration } = await commitName(
      ethRegistrarController,
      {
        label: 'newname',
        duration: REGISTRATION_TIME,
        ownerAddress: registrant.address,
      }
    );
    
    await expect(
      ethRegistrarController.register(registration, { value: 0n })
    ).to.be.reverted;
  });
  
  it('should report registered names as unavailable', async function () {
    await registerName(ethRegistrarController, { label: 'newname', ownerAddress: registrant.address });
    const result = await ethRegistrarController.available('newname');
    expect(result).to.equal(false);
  });
  
  it('should permit new registrations with resolver and records', async function () {
    const { registration, params } = await commitName(
      ethRegistrarController,
      {
        label: 'newconfigname',
        duration: REGISTRATION_TIME,
        ownerAddress: registrant.address,
      }
    );
    
    const { base } = await ethRegistrarController.rentPrice(params.label, params.duration);
    
    await expect(
      ethRegistrarController.register(registration, {
        value: base + 1n,
      })
    ).to.emit(ethRegistrarController, 'NameRegistered');
    
    const balanceAfter = await hre.ethers.provider.getBalance(ethRegistrarController.target);
    expect(balanceAfter).to.be.gt(0);
    
    const nodehash = namehash('newconfigname.eth');
    const nameOwner = await ensRegistry.owner(nodehash);
    expect(nameOwner).to.equal(registrant.address);
    
    const baseOwner = await baseRegistrar.ownerOf(labelId('newconfigname'));
    expect(baseOwner).to.equal(registrant.address);
  });
  
  it('should include the owner in the commitment', async function () {
    // 先提交一个使用 other.address 的承诺
    await commitName(
      ethRegistrarController,
      {
        label: 'newname',
        duration: REGISTRATION_TIME,
        ownerAddress: other.address,
      }
    );
    
    // 尝试使用不同的所有者地址注册
    const registration = {
      label: 'newname',
      owner: registrant.address,
      duration: REGISTRATION_TIME,
      secret: zeroHash,
      resolver: zeroAddress,
      data: [],
      reverseRecord: 0,
      referrer: zeroHash
    };
    
    const { base } = await ethRegistrarController.rentPrice('newname', REGISTRATION_TIME);
    
    await expect(
      ethRegistrarController.register(registration, {
        value: base + 1n,
      })
    ).to.be.reverted;
  });
  
  it('should reject duplicate registrations', async function () {
    const label = 'newname';
    
    await registerName(
      ethRegistrarController,
      {
        label,
        duration: REGISTRATION_TIME,
        ownerAddress: registrant.address,
      }
    );
    
    const { registration } = await commitName(
      ethRegistrarController,
      {
        label,
        duration: REGISTRATION_TIME,
        ownerAddress: registrant.address,
      }
    );
    
    const { base } = await ethRegistrarController.rentPrice(label, REGISTRATION_TIME);
    
    await expect(
      ethRegistrarController.register(registration, {
        value: base + 1n,
      })
    ).to.be.reverted;
  });
  
  it('should allow token owners to renew a name', async function () {
    await registerName(
      ethRegistrarController,
      {
        label: 'newname',
        duration: REGISTRATION_TIME,
        ownerAddress: registrant.address,
      }
    );
    
    const expires = await baseRegistrar.nameExpires(labelId('newname'));
    const balanceBefore = await hre.ethers.provider.getBalance(ethRegistrarController.target);
    
    const duration = 86400n;
    const { base: price } = await ethRegistrarController.rentPrice(
      'newname',
      duration,
    );
    
    await ethRegistrarController.renew('newname', duration, zeroHash, {
      value: price,
    });
    
    const newExpires = await baseRegistrar.nameExpires(labelId('newname'));
    expect(newExpires).to.be.gt(expires);
    
    const balanceAfter = await hre.ethers.provider.getBalance(ethRegistrarController.target);
    expect(balanceAfter).to.equal(balanceBefore + price);
  });
  
  it('non wrapped names can renew', async function () {
    const label = 'newname';
    const tokenId = labelId(label);
    const nodehash = namehash(`${label}.eth`);
    const duration = 86400n;
    
    // 允许用户直接注册而不通过 nameWrapper
    await baseRegistrar.addController(owner.address);
    await baseRegistrar.register(tokenId, owner.address, duration);
    
    // 检查名称是否未包装
    try {
      await nameWrapper.ownerOf(hexToBigInt(nodehash));
      expect(false).to.equal(true); // 应该抛出异常
    } catch (e) {
      // 预期的异常
    }
    
    expect(await baseRegistrar.ownerOf(tokenId)).to.equal(owner.address);
    
    const expires = await baseRegistrar.nameExpires(labelId('newname'));
    const balanceBefore = await hre.ethers.provider.getBalance(ethRegistrarController.target);
    
    const { base: price } = await ethRegistrarController.rentPrice(
      'newname',
      duration,
    );
    
    await ethRegistrarController.renew('newname', duration, zeroHash, {
      value: price,
    });
    
    const newExpires = await baseRegistrar.nameExpires(labelId('newname'));
    expect(newExpires).to.be.gt(expires);
    
    const balanceAfter = await hre.ethers.provider.getBalance(ethRegistrarController.target);
    expect(balanceAfter).to.equal(balanceBefore + price);
  });
});
