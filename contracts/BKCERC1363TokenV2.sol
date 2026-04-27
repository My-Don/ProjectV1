// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1363} from "@openzeppelin/contracts/token/ERC20/extensions/ERC1363.sol";
import {ERC20Capped} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Capped.sol";
import {AccessControlDefaultAdminRules} from "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";

/**
 * @title BKCERC1363TokenV2
 *
 * @notice
 * 这是一个 BKC 代币合约。
 *
 * 大白话功能说明：
 * 1. 它是一个 ERC20 代币。
 * 2. 它支持 ERC1363，也就是 transferAndCall、transferFromAndCall、approveAndCall。
 * 3. 它有最大供应量限制，不能无限增发。
 * 4. 它支持冻结账户，被冻结账户不能转出、不能收款，也不能被 mint 到。
 * 5. 它支持单个铸币、批量铸币、批量等额铸币。
 * 6. 它使用角色权限，不是简单 onlyOwner。
 *
 * 角色说明：
 * - DEFAULT_ADMIN_ROLE：最高管理员，可以分配和回收其他角色。
 * - MINTER_ROLE：铸币角色，可以 mint / batchMint。
 * - FREEZER_ROLE：冻结角色，可以 freeze / unfreeze。
 *
 * 金额单位说明：
 * - 本合约所有 amount / supply 参数，都是 raw units，也就是最小单位。
 * - 因为 ERC20 默认 decimals 是 18，所以：
 *   1 个 BKC = 1 * 10^18
 *   600,000,000 个 BKC = 600000000 * 10^18
 *
 * 部署时建议：
 * - admin 最好填多签钱包地址，不建议直接填个人 EOA 地址。
 * - adminTransferDelay 建议设置成 1 天或者更久，例如 86400 秒。
 */
contract BKCERC1363TokenV2 is ERC1363, ERC20Capped, AccessControlDefaultAdminRules {
    // =============================================================
    //                            角色定义
    // =============================================================

    /**
     * @notice 铸币角色。
     *
     * 大白话：
     * 有这个角色的人，可以调用 mint、batchMint、batchMintEqual。
     */
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /**
     * @notice 冻结角色。
     *
     * 大白话：
     * 有这个角色的人，可以冻结账户，也可以解冻账户。
     */
    bytes32 public constant FREEZER_ROLE = keccak256("FREEZER_ROLE");

    // =============================================================
    //                            错误定义
    // =============================================================

    /**
     * @dev 账户已经被冻结了。
     * @param account 被检查的账户地址。
     */
    error AccountFrozen(address account);

    /**
     * @dev 账户本来就没有被冻结，不能重复解冻。
     * @param account 被检查的账户地址。
     */
    error AccountNotFrozen(address account);

    /**
     * @dev 地址不能是 0 地址。
     */
    error ZeroAddress();

    /**
     * @dev 数量不能是 0。
     */
    error ZeroAmount();

    /**
     * @dev 数组不能为空。
     */
    error EmptyArray();

    /**
     * @dev 两个数组长度不一样。
     */
    error ArrayLengthMismatch();

    /**
     * @dev 批量操作数量超过上限。
     * @param provided 用户传进来的数量。
     * @param max 合约允许的最大数量。
     */
    error ExceedsMaxBatchSize(uint256 provided, uint256 max);

    /**
     * @dev 初始发行量不能大于最大供应量。
     * @param initialSupply 初始发行量。
     * @param cap 最大供应量。
     */
    error InitialSupplyExceedsCap(uint256 initialSupply, uint256 cap);

    /**
     * @dev 还有账户被冻结时，不允许最高管理员直接放弃权限。
     * @param frozenCount 当前被冻结的账户数量。
     */
    error FrozenAccountsRemain(uint256 frozenCount);

    // =============================================================
    //                            事件定义
    // =============================================================

    /**
     * @notice 账户冻结状态变化事件。
     *
     * @param account 被冻结或者被解冻的账户。
     * @param frozen true 表示冻结，false 表示解冻。
     */
    event AccountFreeze(address indexed account, bool frozen);

    /**
     * @notice 批量冻结或批量解冻事件。
     *
     * @param frozen true 表示这次是批量冻结，false 表示这次是批量解冻。
     * @param providedCount 用户一共传了多少个地址。
     * @param changedCount 实际有多少个地址的状态发生了变化。
     */
    event BatchFreeze(bool frozen, uint256 providedCount, uint256 changedCount);

    /**
     * @notice 批量铸币事件。
     *
     * @param recipientsCount 本次给多少个地址铸币。
     * @param totalMinted 本次总共铸造了多少 token，单位是 raw units。
     */
    event BatchMint(uint256 recipientsCount, uint256 totalMinted);

    /**
     * @notice 批量等额铸币事件。
     *
     * @param recipientsCount 本次给多少个地址铸币。
     * @param amountEach 每个地址收到多少 token，单位是 raw units。
     * @param totalMinted 本次总共铸造了多少 token，单位是 raw units。
     */
    event BatchMintEqual(uint256 recipientsCount, uint256 amountEach, uint256 totalMinted);

    // =============================================================
    //                            状态变量
    // =============================================================

    /**
     * @dev 记录某个账户是否被冻结。
     *
     * 大白话：
     * _frozen[地址] = true，说明这个地址被冻结了。
     * _frozen[地址] = false，说明这个地址没有被冻结。
     */
    mapping(address account => bool frozen) private _frozen;

    /**
     * @dev 当前被冻结的账户总数。
     *
     * 大白话：
     * 这个数字用于防止管理员在还有冻结账户时直接放弃管理权限，
     * 否则被冻结的人可能永远无法解冻。
     */
    uint256 private _frozenCount;

    /**
     * @notice 单次批量操作最大地址数量。
     *
     * 大白话：
     * 一次最多处理 200 个地址，避免数组太大导致 gas 太高或者交易失败。
     */
    uint256 public constant MAX_BATCH_SIZE = 200;

    // =============================================================
    //                            构造函数
    // =============================================================

    /**
     * @notice 部署 BKC 代币合约。
     *
     * @param name_ 代币名称，例如 "BKC Token"。
     * @param symbol_ 代币简称，例如 "BKC"。
     * @param initialSupplyRaw 初始发行量，必须是最小单位 raw units。
     *                         例如要发行 6 亿枚，18 位精度下传 600000000 * 10^18。
     * @param maxSupplyRaw 最大供应量，必须是最小单位 raw units。
     *                     后续所有 mint 加起来都不能超过这个值。
     * @param admin 初始管理员地址。
     *              这个地址会拿到 DEFAULT_ADMIN_ROLE、MINTER_ROLE、FREEZER_ROLE。
     *              生产环境建议填多签钱包地址。
     * @param adminTransferDelay 默认管理员权限转移的等待时间，单位是秒。
     *                           例如 86400 表示 1 天。
     */
    constructor(
        string memory name_,
        string memory symbol_,
        uint256 initialSupplyRaw,
        uint256 maxSupplyRaw,
        address admin,
        uint48 adminTransferDelay
    )
        ERC20(name_, symbol_)
        ERC20Capped(maxSupplyRaw)
        AccessControlDefaultAdminRules(adminTransferDelay, admin)
    {
        // 初始发行量不能超过最大供应量。
        if (initialSupplyRaw > maxSupplyRaw) {
            revert InitialSupplyExceedsCap(initialSupplyRaw, maxSupplyRaw);
        }

        // 给 admin 分配铸币权限。
        _grantRole(MINTER_ROLE, admin);

        // 给 admin 分配冻结权限。
        _grantRole(FREEZER_ROLE, admin);

        // 如果初始发行量大于 0，就把初始代币铸给 admin。
        if (initialSupplyRaw > 0) {
            _mint(admin, initialSupplyRaw);
        }
    }

    // =============================================================
    //                            查询函数
    // =============================================================

    /**
     * @notice 查询某个账户是否被冻结。
     *
     * @param account 要查询的账户地址。
     *
     * @return true 表示被冻结，false 表示没有被冻结。
     */
    function isFrozen(address account) external view returns (bool) {
        return _frozen[account];
    }

    /**
     * @notice 查询当前一共有多少个账户被冻结。
     *
     * @return 当前被冻结的账户数量。
     */
    function frozenCount() external view returns (uint256) {
        return _frozenCount;
    }

    // =============================================================
    //                            冻结和解冻
    // =============================================================

    /**
     * @notice 冻结单个账户。
     *
     * 大白话：
     * 被冻结后，这个地址不能转出 token，也不能接收 token。
     *
     * @param account 要冻结的账户地址。
     */
    function freeze(address account) external onlyRole(FREEZER_ROLE) {
        if (!_setFrozen(account, true)) {
            revert AccountFrozen(account);
        }
    }

    /**
     * @notice 解冻单个账户。
     *
     * 大白话：
     * 解冻后，这个地址可以恢复正常转账和收款。
     *
     * @param account 要解冻的账户地址。
     */
    function unfreeze(address account) external onlyRole(FREEZER_ROLE) {
        if (!_setFrozen(account, false)) {
            revert AccountNotFrozen(account);
        }
    }

    /**
     * @notice 批量冻结多个账户。
     *
     * 大白话：
     * 一次性冻结多个地址。
     * 如果其中某个地址已经被冻结，就跳过它，不会报错。
     *
     * @param accounts 要冻结的账户地址列表。
     */
    function batchFreeze(address[] calldata accounts) external onlyRole(FREEZER_ROLE) {
        uint256 changed = _batchSetFrozen(accounts, true);
        emit BatchFreeze(true, accounts.length, changed);
    }

    /**
     * @notice 批量解冻多个账户。
     *
     * 大白话：
     * 一次性解冻多个地址。
     * 如果其中某个地址本来就没有被冻结，就跳过它，不会报错。
     *
     * @param accounts 要解冻的账户地址列表。
     */
    function batchUnfreeze(address[] calldata accounts) external onlyRole(FREEZER_ROLE) {
        uint256 changed = _batchSetFrozen(accounts, false);
        emit BatchFreeze(false, accounts.length, changed);
    }

    // =============================================================
    //                            铸币功能
    // =============================================================

    /**
     * @notice 给单个地址铸币。
     *
     * 大白话：
     * 只有 MINTER_ROLE 可以调用。
     * 铸币后总供应量不能超过 cap。
     *
     * @param to 接收新 token 的地址。
     * @param amount 铸币数量，单位是 raw units。
     *               例如 1 个 BKC = 1 * 10^18。
     */
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        _mint(to, amount);
    }

    /**
     * @notice 批量给多个地址铸造不同数量的 token。
     *
     * 大白话：
     * recipients[i] 会收到 amounts[i] 数量的 token。
     * 两个数组长度必须一样。
     *
     * 举例：
     * recipients = [A, B, C]
     * amounts    = [100, 200, 300]
     *
     * 结果：
     * A 收到 100
     * B 收到 200
     * C 收到 300
     *
     * @param recipients 接收 token 的地址列表。
     * @param amounts 每个地址对应的铸币数量，单位是 raw units。
     */
    function batchMint(
        address[] calldata recipients,
        uint256[] calldata amounts
    ) external onlyRole(MINTER_ROLE) {
        uint256 length = recipients.length;

        // 检查数组不能为空，并且不能超过最大批量数量。
        _checkBatchLength(length);

        // 接收地址数量必须和金额数量一致。
        if (length != amounts.length) revert ArrayLengthMismatch();

        uint256 totalMinted;

        for (uint256 i = 0; i < length; ) {
            address recipient = recipients[i];
            uint256 amount = amounts[i];

            if (recipient == address(0)) revert ZeroAddress();
            if (amount == 0) revert ZeroAmount();

            totalMinted += amount;

            // 真正执行铸币。
            // 如果超过最大供应量，ERC20Capped 会自动 revert。
            // 如果 recipient 被冻结，_update 里会自动 revert。
            _mint(recipient, amount);

            unchecked {
                ++i;
            }
        }

        emit BatchMint(length, totalMinted);
    }

    /**
     * @notice 批量给多个地址铸造相同数量的 token。
     *
     * 大白话：
     * 所有 recipients 里的地址，都会收到一样多的 token。
     *
     * 举例：
     * recipients = [A, B, C]
     * amount = 100
     *
     * 结果：
     * A 收到 100
     * B 收到 100
     * C 收到 100
     *
     * @param recipients 接收 token 的地址列表。
     * @param amount 每个地址收到的 token 数量，单位是 raw units。
     */
    function batchMintEqual(
        address[] calldata recipients,
        uint256 amount
    ) external onlyRole(MINTER_ROLE) {
        uint256 length = recipients.length;

        // 检查数组不能为空，并且不能超过最大批量数量。
        _checkBatchLength(length);

        if (amount == 0) revert ZeroAmount();

        // Solidity 0.8+ 会自动检查乘法溢出。
        uint256 totalMinted = amount * length;

        for (uint256 i = 0; i < length; ) {
            address recipient = recipients[i];

            if (recipient == address(0)) revert ZeroAddress();

            // 真正执行铸币。
            // 如果超过最大供应量，ERC20Capped 会自动 revert。
            // 如果 recipient 被冻结，_update 里会自动 revert。
            _mint(recipient, amount);

            unchecked {
                ++i;
            }
        }

        emit BatchMintEqual(length, amount, totalMinted);
    }

    // =============================================================
    //                            管理员安全保护
    // =============================================================

    /**
     * @notice 放弃某个角色。
     *
     * 大白话：
     * OpenZeppelin 的 AccessControl 本来就支持 renounceRole。
     * 这里额外加了一层保护：
     *
     * 如果还有账户被冻结，最高管理员不能直接放弃 DEFAULT_ADMIN_ROLE。
     * 否则可能出现一个很严重的问题：
     * 有人还被冻结着，但已经没有管理员能解冻他了。
     *
     * @param role 要放弃的角色。
     *             例如 DEFAULT_ADMIN_ROLE、MINTER_ROLE、FREEZER_ROLE。
     * @param account 要放弃角色的账户。
     *                正常情况下，这个 account 应该是调用者自己。
     */
    function renounceRole(
        bytes32 role,
        address account
    ) public override(AccessControlDefaultAdminRules) {
        if (role == DEFAULT_ADMIN_ROLE && account == defaultAdmin() && _frozenCount > 0) {
            revert FrozenAccountsRemain(_frozenCount);
        }

        super.renounceRole(role, account);
    }

    // =============================================================
    //                            多继承重写
    // =============================================================

    /**
     * @notice 查询合约是否支持某个接口。
     *
     * 大白话：
     * 因为这个合约同时继承了 ERC1363 和 AccessControl，
     * 两边都有自己的接口声明，所以这里要把它们合并起来。
     *
     * @param interfaceId 要查询的接口 ID。
     *
     * @return true 表示支持这个接口，false 表示不支持。
     */
    function supportsInterface(
        bytes4 interfaceId
    ) public view override(ERC1363, AccessControlDefaultAdminRules) returns (bool) {
        return
            ERC1363.supportsInterface(interfaceId) ||
            AccessControlDefaultAdminRules.supportsInterface(interfaceId);
    }

    /**
     * @dev ERC20 内部转账、铸币、销毁都会走这里。
     *
     * 大白话：
     * 这是冻结逻辑最关键的地方。
     *
     * 为什么写在 _update 里？
     * 因为在 OpenZeppelin v5 里：
     * - 普通转账 transfer 会走 _update
     * - 授权转账 transferFrom 会走 _update
     * - 铸币 mint 会走 _update
     * - 销毁 burn 如果以后加，也会走 _update
     *
     * 这样可以保证冻结检查不会漏。
     *
     * @param from token 从哪个地址出来。
     *             from 是 0 地址时，表示这是铸币 mint。
     * @param to token 到哪个地址去。
     *           to 是 0 地址时，表示这是销毁 burn。
     * @param value 转账、铸币或者销毁的数量，单位是 raw units。
     */
    function _update(
        address from,
        address to,
        uint256 value
    ) internal override(ERC20, ERC20Capped) {
        // from 不是 0 地址，说明不是 mint。
        // 如果 from 被冻结，就不允许转出。
        if (from != address(0) && _frozen[from]) {
            revert AccountFrozen(from);
        }

        // to 不是 0 地址，说明不是 burn。
        // 如果 to 被冻结，就不允许收款，也不允许 mint 到这个地址。
        if (to != address(0) && _frozen[to]) {
            revert AccountFrozen(to);
        }

        // 继续执行 OpenZeppelin 原本的 ERC20 / ERC20Capped 逻辑。
        // ERC20Capped 会在这里检查是否超过最大供应量。
        super._update(from, to, value);
    }

    // =============================================================
    //                            内部工具函数
    // =============================================================

    /**
     * @dev 批量设置账户冻结状态。
     *
     * 大白话：
     * frozen = true，就是批量冻结。
     * frozen = false，就是批量解冻。
     *
     * @param accounts 要处理的账户列表。
     * @param frozen 要设置成什么状态。
     *               true 表示冻结，false 表示解冻。
     *
     * @return changed 实际发生变化的账户数量。
     */
    function _batchSetFrozen(
        address[] calldata accounts,
        bool frozen
    ) private returns (uint256 changed) {
        uint256 length = accounts.length;

        // 检查数组不能为空，并且不能超过最大批量数量。
        _checkBatchLength(length);

        for (uint256 i = 0; i < length; ) {
            if (_setFrozen(accounts[i], frozen)) {
                unchecked {
                    ++changed;
                }
            }

            unchecked {
                ++i;
            }
        }
    }

    /**
     * @dev 设置单个账户冻结状态。
     *
     * 大白话：
     * 这是 freeze、unfreeze、batchFreeze、batchUnfreeze 最后都会调用的底层函数。
     *
     * @param account 要设置冻结状态的账户。
     * @param frozen true 表示冻结，false 表示解冻。
     *
     * @return changed true 表示状态真的变了，false 表示原来就是这个状态。
     */
    function _setFrozen(address account, bool frozen) private returns (bool changed) {
        if (account == address(0)) revert ZeroAddress();

        bool current = _frozen[account];

        // 如果现在的状态和要设置的状态一样，就不用重复操作。
        if (current == frozen) {
            return false;
        }

        _frozen[account] = frozen;

        if (frozen) {
            // 账户从未冻结变成冻结，冻结数量 +1。
            unchecked {
                ++_frozenCount;
            }
        } else {
            // 账户从冻结变成未冻结，冻结数量 -1。
            unchecked {
                --_frozenCount;
            }
        }

        emit AccountFreeze(account, frozen);

        return true;
    }

    /**
     * @dev 检查批量操作的数组长度。
     *
     * 大白话：
     * 批量操作不能传空数组，也不能一次传太多。
     *
     * @param length 数组长度。
     */
    function _checkBatchLength(uint256 length) private pure {
        if (length == 0) revert EmptyArray();

        if (length > MAX_BATCH_SIZE) {
            revert ExceedsMaxBatchSize(length, MAX_BATCH_SIZE);
        }
    }
}
