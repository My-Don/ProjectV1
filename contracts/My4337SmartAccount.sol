// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
    最终上线模板：ERC-4337 单 owner 智能账户 + CREATE2 工厂。

    设计目标：
    - 单 owner ECDSA 签名控制账户。
    - 支持 ERC-4337 validateUserOp。
    - 支持 execute 单笔调用。
    - 支持 executeBatch 批量调用。
    - 支持 ERC-1271 标准签名校验。
    - 支持自定义 EIP-712 domain-bound 严格签名校验。
    - 支持收 ETH。
    - 支持收 ERC721 / ERC1155。
    - 支持 EntryPoint 押金充值和提现。
    - 支持 CREATE2 反事实地址。
    - 支持账户未部署时生成 initCode。
    - 支持账户已部署时返回空 initCode，方便生产前端省 gas。
    - 提供 version()，方便前端、SDK、监控和测试脚本识别版本。

    重要说明：
    - 这不是多签钱包。
    - 这不是社交恢复钱包。
    - 这不是 Paymaster。
    - 这不是插件化 ERC-7579 账户。
    - 这是一个清晰、可审计、适合作为 ERC-4337 项目基础账户的模板。

    编译建议：
    - npm install @openzeppelin/contracts@5.6.1
    - Hardhat compiler 建议使用 0.8.30。
    - 如果你坚持 compiler 0.8.24，请确保 evmVersion 配置合理。

    上线建议：
    - 跑单元测试。
    - 跑 fork 测试。
    - 跑 bundler simulation。
    - 核对 EntryPoint 地址和 bundler 支持版本。
    - 正式主网上线前做第三方审计。
*/

import {Account} from "@openzeppelin/contracts/account/Account.sol";
import {IEntryPoint} from "@openzeppelin/contracts/interfaces/draft-IERC4337.sol";
import {SignerECDSA} from "@openzeppelin/contracts/utils/cryptography/signers/SignerECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

/**
 * @title My4337SmartAccount
 * @notice 单 owner ERC-4337 智能账户
 */
contract My4337SmartAccount is
    Account,
    SignerECDSA,
    EIP712,
    Initializable,
    ERC721Holder,
    ERC1155Holder,
    IERC1271
{
    /**
     * @notice 账户合约版本。
     *
     * 大白话：
     * - 给前端、SDK、监控系统、测试脚本用。
     * - 避免链上部署多个版本后分不清 ABI / 行为差异。
     */
    string public constant ACCOUNT_VERSION = "1.0.0";

    /**
     * @dev 当前账户绑定的 EntryPoint。
     *
     * 大白话：
     * - ERC-4337 的 UserOperation 都要通过 EntryPoint。
     * - 只有这个 EntryPoint 能调用 validateUserOp。
     * - 只有这个 EntryPoint 或账户自己能调用 execute / executeBatch / changeOwner / withdrawDepositTo。
     */
    IEntryPoint private immutable _entryPoint;

    /**
     * @dev 单次 batch 最大调用数量。
     *
     * 大白话：
     * - 一次最多执行 32 个 call。
     * - 太大容易 gas 爆掉，也会让 bundler 模拟不稳定。
     *
     * 为什么这里硬编码成 constant？
     * - 不占存储。
     * - 没有管理员可改配置，少一个权限风险点。
     * - clone 账户行为稳定，方便审计和前端适配。
     *
     * 如果你的业务确实需要更大 batch：
     * - 改源码里的这个常量。
     * - 重新部署 factory 和 implementation。
     * - 不建议做成运行时可变参数，除非你真的需要治理或管理员配置。
     */
    uint256 public constant MAX_BATCH_SIZE = 32;

    /**
     * @dev ERC-1271 成功魔法值。
     *
     * 标准要求：
     * - 签名有效时返回 0x1626ba7e。
     */
    bytes4 private constant _ERC1271_MAGICVALUE = IERC1271.isValidSignature.selector;

    /**
     * @dev ERC-1271 失败返回值。
     *
     * 常见约定：
     * - 签名无效时返回 0xffffffff。
     */
    bytes4 private constant _ERC1271_INVALID = 0xffffffff;

    /**
     * @dev 自定义 domain-bound 签名的 EIP-712 typehash。
     *
     * 这个不是 ERC-1271 标准的一部分。
     * 它只是给你自己的业务做更清晰、更抗重放的 typed data 验签。
     *
     * 前端 typed data：
     *
     * types: {
     *   ERC1271ReplaySafeMessage: [
     *     { name: "entryPoint", type: "address" },
     *     { name: "appHash", type: "bytes32" }
     *   ]
     * }
     *
     * domain:
     * {
     *   name: "My4337SmartAccount",
     *   version: "1",
     *   chainId: 当前链 ID,
     *   verifyingContract: 当前智能账户地址
     * }
     *
     * message:
     * {
     *   entryPoint: 当前 EntryPoint 地址,
     *   appHash: 你的业务 hash
     * }
     *
     * 注意：
     * - appHash 里仍然应该包含业务 nonce、deadline、订单 ID、DApp ID、目标合约、操作类型等。
     * - 否则同一个 appHash 在同一个账户、同一条链、同一个 EntryPoint 下仍然可以重复验证。
     */
    bytes32 private constant _ERC1271_REPLAY_SAFE_TYPEHASH =
        keccak256("ERC1271ReplaySafeMessage(address entryPoint,bytes32 appHash)");

    error SmartAccountZeroAddress();
    error SmartAccountInvalidTarget();
    error SmartAccountEmptyBatch();
    error SmartAccountBatchTooLarge(uint256 length, uint256 maxLength);
    error SmartAccountInsufficientDeposit(uint256 requested, uint256 available);
    error SmartAccountOwnerUnchanged(address owner);

    event OwnerChanged(address indexed oldOwner, address indexed newOwner);

    /**
     * @notice 单笔执行事件。
     *
     * 大白话：
     * - 不把完整 data 写进 event。
     * - 不把 returnData 写进 event。
     * - 只记录 dataHash，省 gas。
     * - 完整 calldata 可以从交易 input / trace 里拿。
     */
    event Executed(
        address indexed target,
        uint256 value,
        bytes32 indexed dataHash
    );

    /**
     * @notice 批量执行事件。
     *
     * 大白话：
     * - 不把整个 calls 数组写入 event。
     * - 只记录 callsHash。
     * - 完整 calls 可以从交易 input / trace 里还原。
     */
    event BatchExecuted(
        uint256 callsCount,
        bytes32 indexed callsHash
    );

    /**
     * @dev 批量调用结构体。
     *
     * target:
     * - 要调用的目标合约地址。
     *
     * value:
     * - 要带过去的 ETH 数量。
     * - 这笔 ETH 来自智能账户自己的余额。
     *
     * data:
     * - 调用目标合约的 calldata。
     */
    struct Call {
        address target;
        uint256 value;
        bytes data;
    }

    /**
     * @notice implementation 构造函数。
     *
     * 大白话：
     * - Factory 会先部署一个 implementation。
     * - 每个用户账户都是这个 implementation 的 clone。
     * - clone 不跑构造函数，所以 owner 在 initialize 里设置。
     *
     * SignerECDSA(address(type(uint160).max))：
     * - implementation 本身不是用户钱包。
     * - 这里给一个很明显的哑 signer。
     * - 不使用 address(1)，避免让人误以为和 ecrecover 预编译地址有关。
     * - 真正 clone 账户会在 initialize 里写入真实 owner。
     *
     * EIP712("My4337SmartAccount", "1")：
     * - 给自定义 domain-bound ERC-1271 验签辅助函数使用。
     * - 在 clone 场景下，OZ v5.x 的 _domainSeparatorV4 会因为 address(this) 不等于缓存地址而重建 domain。
     * - 重建时 verifyingContract 会是 clone 地址。
     */
    constructor(IEntryPoint entryPoint_)
        SignerECDSA(address(type(uint160).max))
        EIP712("My4337SmartAccount", "1")
    {
        if (address(entryPoint_) == address(0)) {
            revert SmartAccountZeroAddress();
        }

        _entryPoint = entryPoint_;

        // 锁死 implementation，防止别人把 implementation 当成账户初始化。
        _disableInitializers();
    }

    /**
     * @notice 初始化 clone 账户。
     *
     * @param owner_ 账户 owner，一般是用户 EOA。
     *
     * 大白话：
     * - 每个 clone 只能初始化一次。
     * - 工厂部署 clone 后会立刻调用 initialize。
     */
    function initialize(address owner_) external initializer {
        if (owner_ == address(0)) {
            revert SmartAccountZeroAddress();
        }

        _setSigner(owner_);

        emit OwnerChanged(address(0), owner_);
    }

    /**
     * @notice 接收 ETH。
     *
     * 大白话：
     * - 账户可以直接收 ETH。
     * - 收 ETH 不会触发 execute。
     * - 给账户充值普通 ETH，就直接转账到这个账户地址。
     */
    receive() external payable override {}

    /**
     * @notice 返回账户合约版本。
     *
     * @return 当前账户合约版本号。
     */
    function version() external pure returns (string memory) {
        return ACCOUNT_VERSION;
    }

    /**
     * @notice 返回当前账户 owner。
     *
     * @return 当前控制账户的 EOA 地址。
     */
    function owner() external view returns (address) {
        return signer();
    }

    /**
     * @notice 返回当前账户信任的 EntryPoint。
     *
     * @return 当前账户绑定的 EntryPoint 合约。
     */
    function entryPoint() public view override returns (IEntryPoint) {
        return _entryPoint;
    }

    /**
     * @notice 更换账户 owner。
     *
     * @param newOwner 新 owner 地址。
     *
     * 大白话：
     * - 只能通过 EntryPoint 验证后的 UserOperation 调用。
     * - 或者账户自己调用自己。
     * - 不允许把 owner 改成 0 地址。
     * - 不允许把 owner 改成当前 owner。
     */
    function changeOwner(address newOwner) external onlyEntryPointOrSelf {
        if (newOwner == address(0)) {
            revert SmartAccountZeroAddress();
        }

        address oldOwner = signer();

        if (newOwner == oldOwner) {
            revert SmartAccountOwnerUnchanged(newOwner);
        }

        _setSigner(newOwner);

        emit OwnerChanged(oldOwner, newOwner);
    }

    /**
     * @notice 执行一笔外部调用。
     *
     * @param target 目标合约地址。
     * @param value 要从账户余额转出的 ETH 数量。
     * @param data 调用目标合约的 calldata。
     *
     * @return returnData 目标合约返回的数据。
     *
     * 大白话：
     * - 这就是智能账户真正调用外部合约的地方。
     * - 只能 EntryPoint 或账户自己调用。
     * - 这里故意不是 payable。
     * - 如果要给账户转 ETH，直接转到账户地址，走 receive。
     * - event 里只记录 keccak256(data)，不记录完整 data / returnData，节省日志成本。
     */
    function execute(
        address target,
        uint256 value,
        bytes calldata data
    ) external onlyEntryPointOrSelf returns (bytes memory returnData) {
        returnData = _call(target, value, data);

        emit Executed(target, value, keccak256(data));
    }

    /**
     * @notice 批量执行多笔外部调用。
     *
     * @param calls 调用数组。
     *
     * @return returnData 每个 call 的返回数据。
     *
     * 大白话：
     * - 一次 UserOperation 里做多件事。
     * - 例如 approve + swap + transfer。
     * - 空数组会 revert。
     * - 超过 MAX_BATCH_SIZE 会 revert。
     * - 任意一笔失败，整个 batch 回滚。
     * - event 里只记录 callsHash，不记录完整 calls。
     */
    function executeBatch(
        Call[] calldata calls
    ) external onlyEntryPointOrSelf returns (bytes[] memory returnData) {
        uint256 length = calls.length;

        if (length == 0) {
            revert SmartAccountEmptyBatch();
        }

        if (length > MAX_BATCH_SIZE) {
            revert SmartAccountBatchTooLarge(length, MAX_BATCH_SIZE);
        }

        // 只把 calls 的 hash 写进 event。
        // 完整 calls 本来就在交易 calldata 里，链下可以通过 tx input 或 trace 还原。
        bytes32 callsHash = keccak256(abi.encode(calls));

        returnData = new bytes[](length);

        for (uint256 i = 0; i < length; i++) {
            returnData[i] = _call(
                calls[i].target,
                calls[i].value,
                calls[i].data
            );
        }

        emit BatchExecuted(length, callsHash);
    }

    /**
     * @notice 查询账户在 EntryPoint 里的押金余额。
     *
     * @return 当前账户存在 EntryPoint 里的 ETH 押金。
     */
    function getDeposit() public view returns (uint256) {
        return entryPoint().balanceOf(address(this));
    }

    /**
     * @notice 给本账户在 EntryPoint 里充值押金。
     *
     * 大白话：
     * - 任何人都可以帮这个账户充值 EntryPoint 押金。
     * - 押金用于 ERC-4337 UserOperation 的 gas 结算。
     */
    function addDeposit() external payable {
        entryPoint().depositTo{value: msg.value}(address(this));
    }

    /**
     * @notice 从 EntryPoint 提出本账户押金。
     *
     * @param to 接收押金的地址。
     * @param amount 提现金额。
     *
     * 大白话：
     * - 只能通过 EntryPoint 验证后的 UserOperation 调用。
     * - 或者账户自己调用自己。
     * - amount 不能超过当前押金余额。
     */
    function withdrawDepositTo(
        address payable to,
        uint256 amount
    ) external onlyEntryPointOrSelf {
        if (to == address(0)) {
            revert SmartAccountZeroAddress();
        }

        uint256 available = getDeposit();

        if (amount > available) {
            revert SmartAccountInsufficientDeposit(amount, available);
        }

        entryPoint().withdrawTo(to, amount);
    }

    /**
     * @notice 标准 ERC-1271 签名校验。
     *
     * @param hash 调用方传入的 digest。
     * @param signature owner 对 hash 的签名。
     *
     * @return magicValue 签名有效返回 0x1626ba7e，签名无效返回 0xffffffff。
     *
     * 重要安全说明：
     * - 这个函数是为了兼容第三方 DApp。
     * - 它验证的是调用方传进来的 hash。
     * - 它不会自动加入 chainId。
     * - 它不会自动加入 verifyingContract。
     * - 它不会自动加入 nonce。
     * - 它不会自动加入 deadline。
     *
     * 因此：
     * - 第三方 DApp 必须自己保证 hash 已经做好防重放。
     * - 比如 hash 是 EIP-712 digest，并且 domain 里包含 chainId 和 verifyingContract。
     * - 如果 hash 是裸 keccak256(message)，就可能有跨链、跨合约、跨场景重放风险。
     *
     * 更安全的自有业务接入建议：
     * - 不要直接用这个标准函数验裸 hash。
     * - 优先使用 erc1271ReplaySafeHash / isValidReplaySafeSignature / isValidReplaySafeSignature1271。
     */
    function isValidSignature(
        bytes32 hash,
        bytes calldata signature
    ) external view override returns (bytes4 magicValue) {
        bool ok = _rawSignatureValidation(hash, signature);

        return ok ? _ERC1271_MAGICVALUE : _ERC1271_INVALID;
    }

    /**
     * @notice 生成自有业务使用的 EIP-712 domain-bound digest。
     *
     * @param appHash 业务层 hash。
     *
     * @return digest 最终要让 owner 签名的 EIP-712 digest。
     *
     * 大白话：
     * - 这个函数会把 appHash 绑定到：
     *   1. 当前 chainId
     *   2. 当前智能账户地址
     *   3. 当前 EntryPoint 地址
     *
     * 但它不是万能防重放：
     * - 同一个 appHash 在同一个账户、同一条链、同一个 EntryPoint 下仍然会得到同一个 digest。
     * - 所以 appHash 里应该包含业务自己的 nonce、deadline、orderId、actionId、DApp ID、目标合约、操作类型等字段。
     */
    function erc1271ReplaySafeHash(
        bytes32 appHash
    ) public view returns (bytes32 digest) {
        bytes32 structHash = keccak256(
            abi.encode(
                _ERC1271_REPLAY_SAFE_TYPEHASH,
                address(entryPoint()),
                appHash
            )
        );

        return _hashTypedDataV4(structHash);
    }

    /**
     * @notice 自有业务使用的 domain-bound 签名验证，返回 bool。
     *
     * @param appHash 业务层 hash。
     * @param signature owner 对 erc1271ReplaySafeHash(appHash) 的签名。
     *
     * @return valid 签名有效返回 true，否则返回 false。
     *
     * 大白话：
     * - 这个不是 ERC-1271 标准函数。
     * - 这是给你自己的业务合约、后端、前端使用的辅助函数。
     * - 返回 bool 更直观。
     *
     * 注意：
     * - 这个函数是 view，不能消耗 nonce，也不能标记签名已用。
     * - 真正的一次性签名，仍然需要业务合约或后端自己记录 nonce / usedHash。
     */
    function isValidReplaySafeSignature(
        bytes32 appHash,
        bytes calldata signature
    ) external view returns (bool valid) {
        return _isValidReplaySafeSignature(appHash, signature);
    }

    /**
     * @notice 自有业务使用的严格 ERC-1271 风格 wrapper。
     *
     * @param appHash 业务层 hash。
     * @param signature owner 对 erc1271ReplaySafeHash(appHash) 的签名。
     *
     * @return magicValue 签名有效返回 0x1626ba7e，签名无效返回 0xffffffff。
     *
     * 大白话：
     * - 这个函数不是标准 ERC-1271 selector。
     * - 它是“严格模式”验签入口。
     * - 它不会直接验证裸 hash。
     * - 它会先把 appHash 包进 EIP-712 domain：
     *   chainId + 当前账户地址 + 当前 EntryPoint 地址。
     *
     * 推荐接入方式：
     * - 你的自有 DApp、后端、业务合约优先调这个函数。
     * - 第三方通用 DApp 需要兼容 ERC-1271 时，才使用标准 isValidSignature(hash, signature)。
     */
    function isValidReplaySafeSignature1271(
        bytes32 appHash,
        bytes calldata signature
    ) external view returns (bytes4 magicValue) {
        bool ok = _isValidReplaySafeSignature(appHash, signature);

        return ok ? _ERC1271_MAGICVALUE : _ERC1271_INVALID;
    }

    /**
     * @notice ERC165 接口声明。
     *
     * @param interfaceId 接口 ID。
     *
     * @return 支持该接口则返回 true。
     *
     * 大白话：
     * - ERC1155Holder 自带 supportsInterface。
     * - 这里额外声明支持 ERC-1271。
     */
    function supportsInterface(
        bytes4 interfaceId
    ) public view override(ERC1155Holder) returns (bool) {
        return
            interfaceId == type(IERC1271).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    /**
     * @dev 内部 replay-safe 签名验证。
     *
     * @param appHash 业务层 hash。
     * @param signature owner 对 replay-safe digest 的签名。
     *
     * @return valid 签名有效返回 true，否则返回 false。
     */
    function _isValidReplaySafeSignature(
        bytes32 appHash,
        bytes calldata signature
    ) internal view returns (bool valid) {
        return _rawSignatureValidation(
            erc1271ReplaySafeHash(appHash),
            signature
        );
    }

    /**
     * @dev 内部低级调用。
     *
     * @param target 目标地址。
     * @param value 转出的 ETH 数量。
     * @param data 调用 calldata。
     *
     * @return returnData 目标调用返回数据。
     *
     * 大白话：
     * - execute 和 executeBatch 最终都会走这里。
     * - target 不能是 0 地址。
     * - data 保持 calldata，避免无意义 memory 拷贝。
     * - 如果目标调用失败，原样抛出目标合约的 revert reason。
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
 * 大白话：
 * - 工厂负责用 CREATE2 创建账户。
 * - owner + userSalt 可以提前算出账户地址。
 * - 第一次 UserOperation 可以通过 initCode 自动部署账户。
 */
contract My4337SmartAccountFactory {
    /**
     * @notice 工厂合约版本。
     *
     * 大白话：
     * - 给前端、SDK、监控系统、测试脚本用。
     */
    string public constant FACTORY_VERSION = "1.0.0";

    /**
     * @notice 所有 clone 共用的 implementation。
     */
    address public immutable implementation;

    /**
     * @notice 工厂绑定的 EntryPoint。
     */
    IEntryPoint public immutable entryPoint;

    /**
     * @dev EntryPoint 地址为 0。
     *
     * 大白话：
     * - 部署 Factory 时必须传入有效 EntryPoint。
     * - EntryPoint 是 ERC-4337 的核心入口，不能是 0 地址。
     */
    error FactoryEntryPointZeroAddress();

    /**
     * @dev owner 地址为 0。
     *
     * 大白话：
     * - 创建账户、预计算账户地址、生成 initCode 时，owner 不能是 0 地址。
     * - 因为 owner 是真正控制智能账户的人。
     */
    error FactoryOwnerZeroAddress();

    event AccountCreated(
        address indexed account,
        address indexed owner,
        bytes32 indexed userSalt,
        bytes32 finalSalt
    );

    /**
     * @notice 部署工厂。
     *
     * @param entryPoint_ ERC-4337 EntryPoint 地址。
     *
     * 大白话：
     * - 一个 factory 绑定一个 EntryPoint。
     * - 如果要换 EntryPoint 版本，建议重新部署 factory。
     */
    constructor(IEntryPoint entryPoint_) {
        if (address(entryPoint_) == address(0)) {
            revert FactoryEntryPointZeroAddress();
        }

        entryPoint = entryPoint_;

        // 部署 implementation。
        // implementation 构造函数里会锁住 initialize。
        implementation = address(new My4337SmartAccount(entryPoint_));
    }

    /**
     * @notice 返回工厂合约版本。
     *
     * @return 当前工厂合约版本号。
     */
    function version() external pure returns (string memory) {
        return FACTORY_VERSION;
    }

    /**
     * @notice 创建账户；如果账户已存在，直接返回已有账户地址。
     *
     * @param owner_ 账户 owner。
     * @param userSalt_ 用户自定义 salt。
     *
     * @return account 智能账户地址。
     *
     * 大白话：
     * - owner + userSalt 唯一决定账户地址。
     * - 同一组参数不会重复部署。
     * - 谁调用都没关系，因为 owner 是参数里固定传入的。
     */
    function createAccount(
        address owner_,
        bytes32 userSalt_
    ) external returns (address account) {
        _checkOwner(owner_);

        bytes32 finalSalt = _finalSalt(owner_, userSalt_);

        account = _accountAddress(finalSalt);

        if (account.code.length != 0) {
            return account;
        }

        account = Clones.cloneDeterministic(implementation, finalSalt);

        My4337SmartAccount(payable(account)).initialize(owner_);

        emit AccountCreated(account, owner_, userSalt_, finalSalt);
    }

    /**
     * @notice 预计算账户地址，不部署。
     *
     * @param owner_ 账户 owner。
     * @param userSalt_ 用户自定义 salt。
     *
     * @return account 预计算出来的智能账户地址。
     */
    function getAddress(
        address owner_,
        bytes32 userSalt_
    ) external view returns (address account) {
        _checkOwner(owner_);

        bytes32 finalSalt = _finalSalt(owner_, userSalt_);

        return _accountAddress(finalSalt);
    }

    /**
     * @notice 永远生成 ERC-4337 UserOperation 里的 initCode。
     *
     * @param owner_ 账户 owner。
     * @param userSalt_ 用户自定义 salt。
     *
     * @return initCode UserOperation 使用的 initCode。
     *
     * 大白话：
     * - 这个函数无论账户是否已经部署，都会返回 initCode。
     * - 适合某些 SDK 固定想拿 initCode 的场景。
     * - 但生产前端通常更建议用 getInitCodeIfNeeded。
     *
     * 返回格式：
     * - 前 20 字节：factory 地址。
     * - 后面：createAccount(owner, salt) 的 calldata。
     */
    function getInitCode(
        address owner_,
        bytes32 userSalt_
    ) external view returns (bytes memory initCode) {
        _checkOwner(owner_);

        return _initCode(owner_, userSalt_);
    }

    /**
     * @notice 按需生成 initCode。
     *
     * @param owner_ 账户 owner。
     * @param userSalt_ 用户自定义 salt。
     *
     * @return initCode 如果账户未部署，返回 initCode；如果账户已部署，返回空 bytes。
     *
     * 大白话：
     * - 账户还没部署：返回 factory + createAccount calldata。
     * - 账户已经部署：返回空 bytes。
     * - 这个更适合生产前端和后端组装 UserOperation。
     */
    function getInitCodeIfNeeded(
        address owner_,
        bytes32 userSalt_
    ) external view returns (bytes memory initCode) {
        _checkOwner(owner_);

        bytes32 finalSalt = _finalSalt(owner_, userSalt_);
        address account = _accountAddress(finalSalt);

        if (account.code.length != 0) {
            return "";
        }

        return _initCode(owner_, userSalt_);
    }

    /**
     * @dev 检查 owner 不是 0 地址。
     */
    function _checkOwner(address owner_) internal pure {
        if (owner_ == address(0)) {
            revert FactoryOwnerZeroAddress();
        }
    }

    /**
     * @dev 根据 finalSalt 预计算账户地址。
     */
    function _accountAddress(
        bytes32 finalSalt
    ) internal view returns (address account) {
        return Clones.predictDeterministicAddress(
            implementation,
            finalSalt,
            address(this)
        );
    }

    /**
     * @dev 内部生成 initCode。
     *
     * 大白话：
     * - initCode = factory 地址 + createAccount(owner, salt) calldata。
     */
    function _initCode(
        address owner_,
        bytes32 userSalt_
    ) internal view returns (bytes memory initCode) {
        return abi.encodePacked(
            address(this),
            abi.encodeCall(this.createAccount, (owner_, userSalt_))
        );
    }

    /**
     * @dev 内部 salt 生成。
     *
     * @param owner_ 账户 owner。
     * @param userSalt_ 用户自定义 salt。
     *
     * @return finalSalt CREATE2 最终使用的 salt。
     *
     * 大白话：
     * - 不直接用用户传入的 userSalt。
     * - 而是 keccak256(owner, userSalt)。
     * - 避免不同 owner 使用同一个 userSalt 时产生混淆。
     */
    function _finalSalt(
        address owner_,
        bytes32 userSalt_
    ) internal pure returns (bytes32 finalSalt) {
        return keccak256(abi.encode(owner_, userSalt_));
    }
}
