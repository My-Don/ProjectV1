// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
    这份合约是一套“基础版、可上线前审计”的 ERC-4337 智能账户模板。

    它包含两部分：

    1. My4337SmartAccount
       真正的钱包账户。
       每个用户会有一个自己的账户地址。
       这个账户可以：
       - 校验 owner 的 ECDSA 签名
       - 通过 EntryPoint 执行交易
       - 单笔调用 execute
       - 批量调用 executeBatch
       - 收 ETH
       - 收 ERC721 NFT
       - 收 ERC1155 NFT
       - 支持 ERC-1271，方便 DApp 判断“这个智能账户签名是否有效”
       - 给 EntryPoint 充值押金
       - 从 EntryPoint 提回押金

    2. My4337SmartAccountFactory
       账户工厂。
       用 CREATE2/Clones 做确定性部署，也就是：
       - 用户账户还没真正部署前，就能提前算出账户地址
       - 第一次发 UserOperation 时，可以通过 initCode 自动部署账户
       - 同一个 owner + salt 只会对应一个账户地址

    注意：
    - 这不是 Paymaster。
    - 这不是多签。
    - 这不是社交恢复钱包。
    - 这不是插件化 ERC-7579 账户。
    - 这是一个干净、清晰、适合作为正式项目前置模板的 ERC-4337 单 owner 智能账户。
*/

import {Account} from "@openzeppelin/contracts/account/Account.sol";
import {IEntryPoint} from "@openzeppelin/contracts/interfaces/draft-IERC4337.sol";
import {SignerECDSA} from "@openzeppelin/contracts/utils/cryptography/signers/SignerECDSA.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

/**
 * @title My4337SmartAccount
 * @notice ERC-4337 智能账户本体
 *
 * 大白话解释：
 * - 这个合约就是“用户的钱包”。
 * - owner 是真正控制这个钱包的人，一般是一个 EOA 地址。
 * - owner 不直接发普通交易，而是签一个 UserOperation。
 * - bundler 把 UserOperation 交给 EntryPoint。
 * - EntryPoint 调用本合约的 validateUserOp 校验签名。
 * - 校验通过后，EntryPoint 再调用本合约的 execute / executeBatch 执行真正的交易。
 */
contract My4337SmartAccount is
    Account,
    SignerECDSA,
    Initializable,
    ERC721Holder,
    ERC1155Holder,
    IERC1271
{
    /**
     * @dev EntryPoint 是 ERC-4337 的核心调度合约。
     *
     * 为什么做成 immutable？
     * - 一旦账户部署好，就不应该随便换 EntryPoint。
     * - 如果可以被恶意换掉，账户安全边界就坏了。
     *
     * 注意：
     * - 部署 factory 时传进来的 EntryPoint 地址，必须和你的 bundler 使用的 EntryPoint 地址一致。
     * - 比如你用 v0.9 EntryPoint，就传 v0.9 地址。
     * - 你用 v0.8 / v0.7，就传对应版本地址。
     */
    IEntryPoint private immutable _entryPoint;

    /**
     * @dev ERC-1271 魔法值。
     *
     * DApp 调用 isValidSignature 时：
     * - 如果签名有效，返回 0x1626ba7e
     * - 如果签名无效，返回 0xffffffff
     */
    bytes4 private constant _ERC1271_MAGICVALUE = IERC1271.isValidSignature.selector;
    bytes4 private constant _ERC1271_INVALID = 0xffffffff;

    error SmartAccountZeroAddress();
    error SmartAccountInvalidTarget();

    event OwnerChanged(address indexed oldOwner, address indexed newOwner);
    event Executed(address indexed target, uint256 value, bytes data, bytes returnData);
    event BatchExecuted(uint256 callsCount);

    /**
     * @dev 批量执行时用的结构体。
     *
     * target:
     * - 要调用的目标合约地址。
     *
     * value:
     * - 要带过去的 ETH 数量。
     *
     * data:
     * - 要调用的函数 calldata。
     */
    struct Call {
        address target;
        uint256 value;
        bytes data;
    }

    /**
     * @notice 构造函数只给“实现合约 implementation”用。
     *
     * 大白话解释：
     * - 工厂会先部署一个 implementation。
     * - 后续每个用户账户都是这个 implementation 的 clone。
     * - clone 不会跑构造函数，所以真正的 owner 要在 initialize 里设置。
     *
     * 为什么 SignerECDSA(address(1))？
     * - SignerECDSA 的父构造函数要求传一个 signer。
     * - implementation 本身不是用户钱包，不应该被使用。
     * - 所以这里塞一个无意义地址，然后马上 _disableInitializers 锁住 implementation。
     *
     * 为什么 _disableInitializers？
     * - 防止别人直接初始化 implementation。
     * - 真正的用户账户 clone 仍然可以 initialize，因为 clone 有自己的存储。
     */
    constructor(IEntryPoint entryPoint_) SignerECDSA(address(1)) {
        if (address(entryPoint_) == address(0)) {
            revert SmartAccountZeroAddress();
        }

        _entryPoint = entryPoint_;

        // 锁死 implementation，避免别人把 implementation 当账户抢先初始化。
        _disableInitializers();
    }

    /**
     * @notice 初始化 clone 账户，设置 owner。
     *
     * 大白话解释：
     * - 每个 clone 刚创建出来时，owner 还没写进去。
     * - 工厂会在 clone 创建后立刻调用 initialize(owner)。
     * - initializer 保证这个函数只能成功执行一次。
     *
     * 安全点：
     * - 不允许 owner 是 0 地址。
     * - 工厂部署 clone 后立刻初始化，中间没有外部可插队窗口。
     */
    function initialize(address owner_) external initializer {
        if (owner_ == address(0)) {
            revert SmartAccountZeroAddress();
        }

        _setSigner(owner_);

        emit OwnerChanged(address(0), owner_);
    }

    /**
     * @notice 返回当前账户 owner。
     *
     * 大白话解释：
     * - SignerECDSA 里把控制账户的人叫 signer。
     * - 这里为了更像钱包，把它包装成 owner。
     */
    function owner() external view returns (address) {
        return signer();
    }

    /**
     * @notice 返回本账户信任的 EntryPoint。
     *
     * 大白话解释：
     * - 只有这个 EntryPoint 能调用 validateUserOp。
     * - 只有这个 EntryPoint 或账户自己能调用 execute。
     */
    function entryPoint() public view override returns (IEntryPoint) {
        return _entryPoint;
    }

    /**
     * @notice 更换账户 owner。
     *
     * 大白话解释：
     * - 旧 owner 签一个 UserOperation。
     * - UserOperation 的 callData 调这个函数。
     * - 执行成功后，新 owner 接管账户。
     *
     * 为什么 onlyEntryPointOrSelf？
     * - 不能让任何人直接调用改 owner。
     * - 正常路径必须是：
     *   owner 签名 -> EntryPoint 校验 -> 账户执行。
     * - address(this) 自己也可以调用，是为了支持未来账户内部流程或批量调用。
     */
    function changeOwner(address newOwner) external onlyEntryPointOrSelf {
        if (newOwner == address(0)) {
            revert SmartAccountZeroAddress();
        }

        address oldOwner = signer();

        _setSigner(newOwner);

        emit OwnerChanged(oldOwner, newOwner);
    }

    /**
     * @notice 执行一笔外部调用。
     *
     * 大白话解释：
     * - 这就是智能账户真正“花钱 / 调合约”的地方。
     * - 例如：
     *   - 给别人转 ETH
     *   - 调 ERC20.transfer
     *   - 调 NFT 合约
     *   - 调 DeFi 合约
     *
     * 谁能调用？
     * - EntryPoint 可以调用。
     * - 账户自己可以调用。
     *
     * 谁不能调用？
     * - owner 直接用普通交易调用也不行。
     * - 因为 ERC-4337 的安全路径是 UserOperation，不是 owner 直接 msg.sender。
     */
    function execute(
        address target,
        uint256 value,
        bytes calldata data
    ) external payable onlyEntryPointOrSelf returns (bytes memory returnData) {
        returnData = _call(target, value, data);

        emit Executed(target, value, data, returnData);
    }

    /**
     * @notice 批量执行多笔外部调用。
     *
     * 大白话解释：
     * - 一次 UserOperation 里做多件事。
     * - 例如：
     *   1. approve
     *   2. swap
     *   3. transfer
     *
     * 注意：
     * - 当前设计是“只要其中一笔失败，整个批量都回滚”。
     * - 这对资产安全更友好，避免只执行了一半。
     */
    function executeBatch(
        Call[] calldata calls
    ) external payable onlyEntryPointOrSelf returns (bytes[] memory returnData) {
        uint256 length = calls.length;
        returnData = new bytes[](length);

        for (uint256 i = 0; i < length; i++) {
            returnData[i] = _call(calls[i].target, calls[i].value, calls[i].data);
        }

        emit BatchExecuted(length);
    }

    /**
     * @notice 查询这个账户在 EntryPoint 里的押金余额。
     *
     * 大白话解释：
     * - ERC-4337 里，账户可以提前往 EntryPoint 存 ETH。
     * - bundler 执行 UserOperation 时，EntryPoint 会从这个押金里扣 gas。
     */
    function getDeposit() external view returns (uint256) {
        return entryPoint().balanceOf(address(this));
    }

    /**
     * @notice 往 EntryPoint 给本账户充值押金。
     *
     * 大白话解释：
     * - 任何人都可以帮这个账户充值。
     * - 充值的钱记在 EntryPoint 里，归本账户所有。
     */
    function addDeposit() external payable {
        entryPoint().depositTo{value: msg.value}(address(this));
    }

    /**
     * @notice 从 EntryPoint 把本账户押金提出来。
     *
     * 大白话解释：
     * - 只有通过 UserOperation 验证后的账户操作，才能把押金取走。
     * - 防止外部地址直接把押金偷走。
     */
    function withdrawDepositTo(
        address payable to,
        uint256 amount
    ) external onlyEntryPointOrSelf {
        if (to == address(0)) {
            revert SmartAccountZeroAddress();
        }

        entryPoint().withdrawTo(to, amount);
    }

    /**
     * @notice ERC-1271 签名校验。
     *
     * 大白话解释：
     * - 很多 DApp 会问：
     *   “这个智能合约钱包是不是真的同意了这个签名？”
     * - EOA 可以用 ecrecover。
     * - 智能账户没有私钥，所以要实现 ERC-1271。
     *
     * 这里的规则：
     * - 只要当前 owner 的 ECDSA 签名能验证 hash，就返回成功魔法值。
     *
     * 注意：
     * - 这里验证的是“传进来的 hash 本身”。
     * - 前端/后端必须保证 hash 的生成方式和 DApp 预期一致。
     */
    function isValidSignature(
        bytes32 hash,
        bytes calldata signature
    ) external view override returns (bytes4) {
        bool ok = _rawSignatureValidation(hash, signature);

        return ok ? _ERC1271_MAGICVALUE : _ERC1271_INVALID;
    }

    /**
     * @notice ERC165 接口声明。
     *
     * 大白话解释：
     * - ERC1155Holder 自带 supportsInterface。
     * - 这里额外告诉外界：我也支持 ERC-1271。
     */
    function supportsInterface(
        bytes4 interfaceId
    ) public view override(ERC1155Holder) returns (bool) {
        return interfaceId == type(IERC1271).interfaceId || super.supportsInterface(interfaceId);
    }

    /**
     * @dev 内部低级调用函数。
     *
     * 大白话解释：
     * - 真正调用 target 的地方。
     * - 如果 target 调用失败，把 target 的失败原因原样抛出去。
     * - 这样前端、bundler、测试脚本能看到真实 revert reason。
     */
    function _call(
        address target,
        uint256 value,
        bytes calldata data
    ) internal returns (bytes memory returnData) {
        if (target == address(0)) {
            revert SmartAccountInvalidTarget();
        }

        bool success;

        (success, returnData) = target.call{value: value}(data);

        if (!success) {
            assembly ("memory-safe") {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }
    }
}

/**
 * @title My4337SmartAccountFactory
 * @notice ERC-4337 智能账户工厂
 *
 * 大白话解释：
 * - 工厂负责创建用户的钱包账户。
 * - 使用 CREATE2 deterministic clone。
 * - 也就是还没部署前，就能算出账户地址。
 *
 * ERC-4337 典型流程：
 * 1. 前端调用 getAddress(owner, salt)，提前算出账户地址。
 * 2. 如果账户还没部署，UserOperation 里填 initCode。
 * 3. initCode = factory 地址 + createAccount(owner, salt) 的 calldata。
 * 4. EntryPoint 在处理 UserOperation 时，会先调用工厂部署账户。
 * 5. 部署完后，EntryPoint 再调用账户的 validateUserOp。
 */
contract My4337SmartAccountFactory {
    /**
     * @notice 所有 clone 都指向这个 implementation。
     *
     * 大白话解释：
     * - implementation 是逻辑合约。
     * - 每个用户账户是一个很小的 clone。
     * - clone 通过 delegatecall 使用 implementation 的代码。
     * - 每个 clone 有自己的独立存储，所以每个用户的 owner 不一样。
     */
    address public immutable implementation;

    /**
     * @notice 这个工厂创建出来的账户统一绑定这个 EntryPoint。
     */
    IEntryPoint public immutable entryPoint;

    error FactoryZeroAddress();

    event AccountCreated(
        address indexed account,
        address indexed owner,
        bytes32 indexed userSalt,
        bytes32 finalSalt
    );

    /**
     * @notice 部署工厂时，传入你要使用的 EntryPoint 地址。
     *
     * 大白话解释：
     * - 一个 factory 通常绑定一个 EntryPoint。
     * - 如果你要换 EntryPoint 版本，建议重新部署 factory。
     */
    constructor(IEntryPoint entryPoint_) {
        if (address(entryPoint_) == address(0)) {
            revert FactoryZeroAddress();
        }

        entryPoint = entryPoint_;

        // 部署 implementation。
        // implementation 构造函数里会锁住 initialize，避免被别人直接初始化。
        implementation = address(new My4337SmartAccount(entryPoint_));
    }

    /**
     * @notice 创建账户；如果账户已经存在，就直接返回已有地址。
     *
     * 大白话解释：
     * - owner + salt 唯一决定一个账户地址。
     * - 同一组参数不会重复部署。
     * - 谁来调用都没关系，因为 owner 是显式传入并立即初始化的，别人抢跑也不能改成自己的 owner。
     */
    function createAccount(
        address owner_,
        bytes32 userSalt_
    ) external returns (address account) {
        if (owner_ == address(0)) {
            revert FactoryZeroAddress();
        }

        bytes32 finalSalt = _finalSalt(owner_, userSalt_);

        account = Clones.predictDeterministicAddress(
            implementation,
            finalSalt,
            address(this)
        );

        // 如果已经部署过，直接返回。
        // 这对 ERC-4337 很重要，因为某些情况下 bundler 或前端可能重复模拟。
        if (account.code.length != 0) {
            return account;
        }

        // 用 CREATE2 部署 clone。
        account = Clones.cloneDeterministic(implementation, finalSalt);

        // 部署后立即初始化 owner。
        // 这一步必须和部署在同一个交易里完成，避免未初始化账户被别人接管。
        My4337SmartAccount(payable(account)).initialize(owner_);

        emit AccountCreated(account, owner_, userSalt_, finalSalt);
    }

    /**
     * @notice 计算 owner + salt 对应的账户地址。
     *
     * 大白话解释：
     * - 不会真的部署账户。
     * - 只是提前算地址。
     * - 前端创建 UserOperation 前通常会先调这个函数。
     */
    function getAddress(
        address owner_,
        bytes32 userSalt_
    ) external view returns (address) {
        bytes32 finalSalt = _finalSalt(owner_, userSalt_);

        return Clones.predictDeterministicAddress(
            implementation,
            finalSalt,
            address(this)
        );
    }

    /**
     * @notice 生成 ERC-4337 UserOperation 里的 initCode。
     *
     * 大白话解释：
     * - 如果账户还没部署，UserOperation 需要带 initCode。
     * - EntryPoint 会根据 initCode 去调用 factory。
     *
     * 返回值格式：
     * - 前 20 字节：factory 地址
     * - 后面：createAccount(owner, salt) 的 calldata
     *
     * 前端也可以自己拼：
     * abi.encodePacked(
     *     address(factory),
     *     abi.encodeCall(factory.createAccount, (owner, salt))
     * )
     */
    function getInitCode(
        address owner_,
        bytes32 userSalt_
    ) external view returns (bytes memory) {
        return abi.encodePacked(
            address(this),
            abi.encodeCall(this.createAccount, (owner_, userSalt_))
        );
    }

    /**
     * @dev 内部 salt 生成函数。
     *
     * 大白话解释：
     * - 不直接使用用户传入的 userSalt。
     * - 而是 keccak256(owner, userSalt)。
     * - 好处是不同 owner 用同一个 salt，也不会撞出同一个地址。
     */
    function _finalSalt(
        address owner_,
        bytes32 userSalt_
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(owner_, userSalt_));
    }
}